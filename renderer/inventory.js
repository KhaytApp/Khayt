/**
 * Inventory tab, product catalog, purchase orders, NFC spool import.
 */
// Bed Ready swaps decorative emoji for its bespoke drafting glyphs (evaluated at render time,
// after bedready-icons.js loads); Khayt keeps the emoji. `_iIco` = icon only, `_iIcoL` adds a space.
const _invBdr = (typeof document !== 'undefined' && document.documentElement && document.documentElement.dataset.app === 'bedready');
/* The flavour's own set, then the shared line icons, then the emoji — the same
 * order printfiles.js and kanban.js use. This asked the Bed Ready set or fell
 * straight to the glyph, so every Khayt screen here drew emoji. `emoji` is
 * optional now; a name neither set draws yields '' rather than 'undefined'. */
function _iGlyph(name, emoji, size) {
  if (_invBdr && window.BedReadyIcons) return `<span class="br-ico">${window.BedReadyIcons.get(name, size || 15)}</span>`;
  const svg = (typeof window !== 'undefined' && window.KhaytIcons) ? window.KhaytIcons.icon(name, size || 15) : '';
  if (svg) return `<span class="pf-ico" aria-hidden="true">${svg}</span>`;
  return emoji || '';
}
function _iIco(name, emoji, size) { return _iGlyph(name, emoji, size); }
function _iIcoL(name, emoji, size) { const g = _iGlyph(name, emoji, size); return g ? (/^<span/.test(g) ? g : g + ' ') : ''; }
let catalogSearchTerm = '';
let invSearchTerm = '';
let supplierSearchTerm = '';
let poSearchTerm = '';
let poStatusFilter = '';
let poDisplayLimit = 50;        // pagination: rows shown in PO table
let _lastPoFilterHash = '';     // detects filter changes to reset PO page
// Filament manufacturer catalog (loaded from filaments-db.json)
let filamentsDB = [];
if (typeof fetch === 'function' && typeof document !== 'undefined') {
  fetch('./filaments-db.json').then(r => r.json()).then(data => { filamentsDB = data; }).catch(e => {
    console.warn('filaments-db.json not loaded:', e);
    filamentsDB = null;
    const catalogEl = document.getElementById('filamentCatalog') || document.getElementById('filamentDbSection');
    if (catalogEl) catalogEl.innerHTML = `<p style="color:var(--text-muted);padding:12px;font-size:13px;">${_iIcoL('alert', '⚠', 12)}${escapeHtml(t('inv.catalog_unavailable') || 'Filament catalog unavailable')}</p>`;
  });
}

(function (global) {
/** The shelf's rules, however this file happens to be loaded. */
const SpoolEdit = (typeof globalThis !== 'undefined' && globalThis.KhaytSpoolEdit)
  || (() => { try { return require('../lib/spool-edit.js'); } catch (e) { return null; } })();

/**
 * Single source of truth for the low-stock test. An item is low when its
 * remaining weight is at or below its reorder point, falling back to the
 * configured threshold and finally the 200g default. Used by the banner,
 * the inventory row badge, reorder lists and auto-deduction so they never
 * disagree.
 */
function isLowStock(item) {
  return isLowStockShared(item);
}

// Set the add-form colour picker + keep its hex text field in sync.
function setInvColor(hex) {
  if (!hex) return;
  const c = $('#invColor'); if (c) c.value = hex;
  const h = $('#invColorHex'); if (h) h.value = String(hex).toUpperCase();
}

/* ============================================================
   Per-location inventory — pure, unit-tested helpers (#65 follow-up)
   ------------------------------------------------------------
   Stock used to be a single global pool; the top-bar location filter
   only scoped jobs/machines/dashboard. These helpers mirror
   orderMatchesActiveLocation so the inventory list, low-stock banner,
   reorder/PO list and valuation can scope to one branch.

   Migration safety: spools/consumables saved before this change have no
   `locationId`. They are treated as "unassigned" and stay visible under
   ANY active location (never hidden), so existing stock is never lost.
   ============================================================ */

/**
 * Does this stock item belong to the active location?
 * - No active filter  → always true (showing all sites).
 * - Item unassigned   → always true (legacy stock visible everywhere).
 * - Otherwise         → exact location match.
 */
function spoolMatchesLocation(item, activeLoc) {
  if (!activeLoc) return true;
  if (!item || !item.locationId) return true;
  return item.locationId === activeLoc;
}

/** Filter a list of stock items to those visible under the active location. */
function filterInventoryByLocation(items, activeLoc) {
  if (!Array.isArray(items)) return [];
  if (!activeLoc) return items.slice();
  return items.filter((it) => spoolMatchesLocation(it, activeLoc));
}

/**
 * Count low-stock items per location id.
 * Returns a map: { [locationId]: count, _unassigned: count }.
 * Pure — caller supplies the low-stock predicate so this stays decoupled
 * from settings/thresholds.
 */
function perLocationLowStockCounts(items, lowFn) {
  const isLow = typeof lowFn === 'function' ? lowFn : isLowStock;
  const out = {};
  (Array.isArray(items) ? items : []).forEach((it) => {
    if (!isLow(it)) return;
    const key = it && it.locationId ? it.locationId : '_unassigned';
    out[key] = (out[key] || 0) + 1;
  });
  return out;
}

/**
 * Order candidate spools by location preference for deduction: spools at the
 * order's location first, then unassigned (shared) spools, then any other
 * branch. Pure & stable within each tier. Used by deductFilamentForOrder so
 * multi-site deduction draws down local stock first.
 */
function orderSpoolsByLocationPreference(candidates, locId) {
  return Deduction().spoolsByLocationPreference(candidates, locId);
}

/* ============================================================
   CSV import — Spools / Inventory
   ============================================================ */
function importSpoolsCsv() {
  openCsvImportModal({
    title: t('csv.import_spools') || 'Import Spools from CSV',
    fields: [
      { key: 'material',        label: t('inv.material')        || 'Material',            required: true },
      { key: 'brand',           label: t('inv.brand')           || 'Brand' },
      { key: 'color',           label: t('inv.color')           || 'Color' },
      { key: 'lot',             label: t('inv.lot')             || 'Lot / Batch' },
      { key: 'diameter',        label: t('inv.diameter')        || 'Diameter (mm)',        type: 'number' },
      { key: 'weightTotal',     label: t('inv.weight_total')    || 'Total Weight (g)',     type: 'number' },
      { key: 'weightRemaining', label: t('inv.remaining')       || 'Remaining (g)',        type: 'number' },
      { key: 'costPerKg',       label: t('inv.cost_per_kg')     || 'Cost/kg',              type: 'number' },
      { key: 'reorderPoint',    label: t('inv.reorder_point')   || 'Reorder Point (g)',    type: 'number' },
      { key: 'location',        label: t('inv.location')        || 'Location' },
      { key: 'notes',           label: t('common.notes')        || 'Notes' },
    ],
    onImport: (rows) => {
      let imported = 0, skipped = 0;
      rows.forEach(row => {
        const exists = (inventory || []).some(s =>
          s.material?.toLowerCase() === row.material?.toLowerCase() &&
          s.brand?.toLowerCase() === (row.brand || '').toLowerCase() &&
          s.color?.toLowerCase() === (row.color || '').toLowerCase()
        );
        if (exists) { skipped++; return; }
        const wt = row.weightTotal || 1000;
        inventory.push({
          id: uid('S'),
          material: row.material,
          brand: row.brand || '',
          color: row.color || '',
          lot: row.lot || undefined,
          diameter: row.diameter || 1.75,
          weight: row.weightRemaining != null ? row.weightRemaining : wt,
          weightTotal: wt,
          cost: row.costPerKg || 0,
          reorderPoint: row.reorderPoint ?? (settings.lowStockThreshold ?? 200),
          location: row.location || '',
          notes: row.notes || '',
          addedAt: localDateStr(),
          usageHistory: [],
        });
        imported++;
      });
      saveAll();
      renderInventory();
      return { imported, skipped };
    }
  });
}

/* ============================================================
   CSV import — Clients
   ============================================================ */
function importClientsCsv() {
  openCsvImportModal({
    title: t('csv.import_clients') || 'Import Clients from CSV',
    fields: [
      { key: 'nameEn',    label: t('cl.name_en')   || 'Name (English)',  required: true },
      { key: 'nameAr',    label: t('cl.name_ar')   || 'Name (Arabic)' },
      { key: 'phone',     label: t('cl.phone')     || 'Phone' },
      { key: 'email',     label: t('cl.email')     || 'Email' },
      { key: 'city',      label: t('cl.city')      || 'City' },
      { key: 'address',   label: t('cl.address')   || 'Address' },
      { key: 'vatNumber', label: t('cl.vat')       || 'VAT Number' },
      { key: 'company',   label: t('cl.company')   || 'Company' },
      { key: 'notes',     label: t('common.notes') || 'Notes' },
    ],
    onImport: (rows) => {
      let imported = 0, skipped = 0;
      rows.forEach(row => {
        const exists = (clients || []).some(c =>
          (c.nameEn?.toLowerCase() === row.nameEn?.toLowerCase()) ||
          (row.phone && c.phone === row.phone) ||
          (row.email && c.email?.toLowerCase() === row.email?.toLowerCase())
        );
        if (exists) { skipped++; return; }
        clients.push({
          id: uid('CL'),
          nameEn: row.nameEn,
          nameAr: row.nameAr || '',
          phone: row.phone || '',
          email: row.email || '',
          city: row.city || '',
          address: row.address || '',
          vat: row.vatNumber || '',
          company: row.company || '',
          notes: row.notes || '',
          createdAt: localDateStr(),
          commLog: [],
          loyaltyTier: 'standard',
        });
        imported++;
      });
      saveAll();
      renderClients();
      return { imported, skipped };
    }
  });
}

/* ============================================================
   CSV import — Products / Catalog
   ============================================================ */
function importProductsCsv() {
  openCsvImportModal({
    title: t('csv.import_products') || 'Import Products from CSV',
    fields: [
      { key: 'nameEn',        label: t('pe.name_en')     || 'Name (English)',   required: true },
      { key: 'nameAr',        label: t('pe.name_ar')     || 'Name (Arabic)' },
      { key: 'description',   label: t('pe.description') || 'Description' },
      { key: 'defaultMargin', label: t('pe.default_margin') || 'Default Margin (%)', type: 'number' },
      { key: 'sku',           label: t('cat.sku')        || 'SKU' },
    ],
    onImport: (rows) => {
      let imported = 0, skipped = 0;
      rows.forEach(row => {
        const exists = (products || []).some(p =>
          (p.nameEn?.toLowerCase() === row.nameEn?.toLowerCase()) ||
          (row.sku && p.sku === row.sku)
        );
        if (exists) { skipped++; return; }
        products.push({
          id: uid('PROD'),
          nameEn: row.nameEn,
          nameAr: row.nameAr || '',
          description: row.description || '',
          defaultMargin: row.defaultMargin || 30,
          sku: row.sku || '',
          thumbnail: null,
          imagePath: null,
          priceTiers: [],
          parts: [],
          createdAt: localDateStr(),
        });
        imported++;
      });
      saveAll();
      renderCatalog();
      return { imported, skipped };
    }
  });
}


/* ============================================================
   Inventory
   ============================================================ */

function openFilamentCatalog() {
  if (filamentsDB === null) { toast(t('inv.catalog_unavailable') || 'Filament catalog unavailable', 'error'); return; }
  if (!filamentsDB || !filamentsDB.length) { toast(t('inv.catalog_loading') || 'Catalog not ready yet', 'error'); return; }

  const brands = [...new Set(filamentsDB.map(f => f.brand))].sort();
  const types  = [...new Set(filamentsDB.map(f => f.type))].sort();

  const bodyHtml = `
    <div style="display:flex; gap:8px; margin-bottom:12px; flex-wrap:wrap; align-items:center;">
      <input type="search" id="catSearch" placeholder="${escapeHtml(t('inv.catalog_search_ph') || 'Search brand, color, type…')}"
        style="flex:1; min-width:160px; padding:7px 10px; border-radius:var(--radius-sm); border:1px solid var(--border); background:var(--surface-2); color:var(--text); font-size:13px;">
      <select id="catBrand" style="padding:7px 10px; border-radius:var(--radius-sm); border:1px solid var(--border); background:var(--surface-2); color:var(--text); font-size:13px;">
        <option value="">${escapeHtml(t('inv.catalog_all_brands') || 'All brands')}</option>
        ${brands.map(b => `<option value="${escapeHtml(b)}">${escapeHtml(b)}</option>`).join('')}
      </select>
      <select id="catType" style="padding:7px 10px; border-radius:var(--radius-sm); border:1px solid var(--border); background:var(--surface-2); color:var(--text); font-size:13px;">
        <option value="">${escapeHtml(t('inv.catalog_all_types') || 'All types')}</option>
        ${types.map(tp => `<option value="${escapeHtml(tp)}">${escapeHtml(tp)}</option>`).join('')}
      </select>
    </div>
    <p style="font-size:12px; color:var(--text-muted); margin-bottom:10px;">${escapeHtml(t('inv.catalog_hint') || 'Click a filament to fill the add form.')}</p>
    <div id="catGrid" class="filament-cat-grid"></div>
  `;

  openFormModal({
    title: t('inv.catalog_title') || 'Browse Filament Catalog',
    bodyHtml,
    noSave: true,
    onMount() {
      function renderCatalogGrid() {
        const q     = document.getElementById('catSearch').value.toLowerCase();
        const brand = document.getElementById('catBrand').value;
        const tp    = document.getElementById('catType').value;

        const filtered = filamentsDB.filter(f => {
          if (brand && f.brand !== brand) return false;
          if (tp    && f.type  !== tp)    return false;
          if (q) {
            const hay = `${f.brand} ${f.line} ${f.type} ${f.color}`.toLowerCase();
            if (!hay.includes(q)) return false;
          }
          return true;
        });

        const grid = document.getElementById('catGrid');
        if (!filtered.length) {
          grid.innerHTML = `<div style="grid-column:1/-1; text-align:center; padding:40px; color:var(--text-muted);">${escapeHtml(t('inv.catalog_no_results') || 'No filaments match')}</div>`;
          return;
        }

        grid.innerHTML = filtered.map((f, i) => `
          <button type="button" class="fil-card" data-idx="${i}" aria-label="${escapeHtml(`${f.brand} ${f.line} ${f.color} ${f.type}`)}">
            <div class="fil-card-swatch" style="background:${safeCssColor(f.hex)};"></div>
            <div class="fil-card-info">
              <span class="fil-card-color">${escapeHtml(f.color)}</span>
              <span class="fil-card-brand">${escapeHtml(f.brand)}</span>
              <span class="fil-card-line">${escapeHtml(f.line)}</span>
              <span class="fil-card-type">${escapeHtml(f.type)}</span>
            </div>
          </button>`).join('');

        grid.querySelectorAll('.fil-card').forEach(card => {
          const f = filtered[+card.dataset.idx];
          card.addEventListener('click', () => {
            $('#invMaterial').value = `${f.brand} ${f.line} – ${f.color}`;
            setInvColor(f.hex);
            $('#modalMount').innerHTML = '';
            toast(t('inv.catalog_picked') || `${f.color} selected`, 'success', 1800);
          });
        });
      }

      renderCatalogGrid();
      document.getElementById('catSearch').addEventListener('input',  renderCatalogGrid);
      document.getElementById('catBrand').addEventListener('change',  renderCatalogGrid);
      document.getElementById('catType').addEventListener('change',   renderCatalogGrid);
    }
  });
}

/* ── NFC tag parsers ──────────────────────────────────────────────────────
   Two open standards supported:
   1. OpenTag3D  — binary fixed offsets, NDEF MIME: application/opentag3d
                   https://opentag3d.info/spec
   2. OpenPrintTag (Prusa) — CBOR map, NDEF MIME: application/vnd.openprinttag
                   https://openprinttag.org
   On macOS desktop: user pastes a raw hex dump from an NFC reader app.
   On iOS (future): auto-read via Capacitor NFC plugin.
   ──────────────────────────────────────────────────────────────────────── */

// ── OpenTag3D ──────────────────────────────────────────────────────────────
function _ot3dReadStr(bytes, offset, len) {
  const slice = bytes.slice(offset, offset + len);
  const nullIdx = slice.indexOf(0);
  return new TextDecoder('utf-8').decode(slice.slice(0, nullIdx === -1 ? len : nullIdx)).trim();
}
function parseOpenTag3DBytes(bytes) {
  if (!bytes || bytes.length < 0x66) return null;
  const u16 = (o) => (bytes[o] << 8) | bytes[o + 1];
  const u8  = (o) => bytes[o];
  const str = (o, l) => _ot3dReadStr(bytes, o, l);

  const baseMaterial = str(0x02, 5);
  if (!baseMaterial) return null; // empty tag

  const modifiers    = str(0x07, 5);
  const manufacturer = str(0x1B, 16);
  const colorName    = str(0x2B, 32);
  const r = u8(0x4B), g = u8(0x4C), b = u8(0x4D);
  const hex = (r || g || b) ? '#' + [r, g, b].map(x => x.toString(16).padStart(2, '0')).join('') : null;
  const weight    = u16(0x5E);
  const printTemp = u8(0x60) * 5;
  const bedTemp   = u8(0x61) * 5;
  const density   = u16(0x62) / 1000;
  const diameter  = u16(0x5C) / 1000;

  let minPrint, maxPrint, minBed, maxBed, dryTemp, dryTime;
  if (bytes.length > 0xB8) {
    minPrint = u8(0xB4) * 5; maxPrint = u8(0xB5) * 5;
    minBed   = u8(0xB6) * 5; maxBed   = u8(0xB7) * 5;
    dryTemp  = u8(0xB2) * 5; dryTime  = u8(0xB3); // hours
  }

  return {
    standard: 'OpenTag3D',
    manufacturer, colorName, hex, weight, density, diameter,
    material: modifiers ? `${baseMaterial} ${modifiers}`.trim() : baseMaterial,
    printTemp, bedTemp, minPrint, maxPrint, minBed, maxBed, dryTemp, dryTime
  };
}

// ── Minimal CBOR decoder ───────────────────────────────────────────────────
function _decodeCBOR(buf, off = 0, depth = 0) {
  if (depth > 32 || off >= buf.length) return { v: null, off };
  const first = buf[off++];
  const major = first >> 5;
  const info  = first & 0x1F;

  function count() {
    if (info <= 23) return { n: info, off };
    if (info === 24) return { n: buf[off],             off: off + 1 };
    if (info === 25) return { n: (buf[off] << 8) | buf[off + 1], off: off + 2 };
    if (info === 26) return { n: ((buf[off] << 24) | (buf[off+1] << 16) | (buf[off+2] << 8) | buf[off+3]) >>> 0, off: off + 4 };
    return { n: 0, off }; // 64-bit: treat as 0
  }
  const { n, off: o2 } = count(); off = o2;

  switch (major) {
    case 0: return { v: n, off };                                      // uint
    case 1: return { v: -1 - n, off };                                 // negint
    case 2: { const len = Math.min(n >>> 0, buf.length - off); return { v: buf.slice(off, off + len), off: off + len }; } // bytes
    case 3: { const len = Math.min(n >>> 0, buf.length - off); return { v: new TextDecoder().decode(buf.slice(off, off + len)), off: off + len }; } // text
    case 4: {                                                           // array
      const arr = [];
      for (let i = 0; i < n && off < buf.length; i++) { const r = _decodeCBOR(buf, off, depth + 1); arr.push(r.v); off = r.off; }
      return { v: arr, off };
    }
    case 5: {                                                           // map
      const map = {};
      for (let i = 0; i < n && off < buf.length; i++) {
        const k = _decodeCBOR(buf, off, depth + 1); off = k.off;
        const vv = _decodeCBOR(buf, off, depth + 1); off = vv.off;
        map[k.v] = vv.v;
      }
      return { v: map, off };
    }
    case 6: return _decodeCBOR(buf, off, depth + 1);                   // tag — skip, decode inner
    case 7: {                                                           // float / special
      if (info === 20) return { v: false, off };
      if (info === 21) return { v: true, off };
      if (info === 22) return { v: null, off };
      if (info === 25) {
        const h = (buf[off] << 8) | buf[off + 1]; off += 2;
        const exp = (h >> 10) & 0x1f, mant = h & 0x3ff;
        const val = exp === 0 ? (mant / 1024) * 2 ** -14
          : exp === 31 ? (mant ? NaN : Infinity)
          : (1 + mant / 1024) * 2 ** (exp - 15);
        return { v: (h >> 15) ? -val : val, off };
      }
      if (info === 26) { const dv = new DataView(buf.buffer, buf.byteOffset + off, 4); return { v: dv.getFloat32(0, false), off: off + 4 }; }
      if (info === 27) { const dv = new DataView(buf.buffer, buf.byteOffset + off, 8); return { v: dv.getFloat64(0, false), off: off + 8 }; }
      return { v: undefined, off };
    }
    default: return { v: null, off };
  }
}

// ── OpenPrintTag (Prusa) CBOR parser ──────────────────────────────────────
// NDEF MIME: application/vnd.openprinttag   Spec: https://openprinttag.org
// Field keys from FieldKeys.swift (https://github.com/marcelkraus/open-print-tag-kit)
const _OPT_MATERIALS = {
  0:'PLA', 1:'PETG', 2:'TPU', 3:'ABS', 4:'ASA', 5:'PC', 6:'PCTG',
  7:'PP', 8:'PA6', 9:'PA11', 10:'PA12', 11:'PA66', 12:'CPE', 13:'TPE',
  14:'HIPS', 15:'PHA', 16:'PET', 17:'PEI', 18:'PBT', 19:'PVB',
  20:'PVA', 21:'PEKK', 22:'PEEK', 23:'BVOH', 24:'TPC', 25:'PPS',
  26:'PPSU', 27:'PVC', 28:'PEBA', 29:'PVDF', 30:'PPA', 31:'PCL',
  32:'PES', 33:'PMMA', 34:'POM', 35:'PPE', 36:'PS', 37:'PSU',
  38:'TPI', 39:'SBS', 40:'OBC', 41:'EVA'
};
function parseOpenPrintTagCBOR(bytes) {
  try {
    const { v: data } = _decodeCBOR(bytes);
    if (!data || typeof data !== 'object' || Array.isArray(data)) return null;

    const matType = data[9] !== undefined ? (_OPT_MATERIALS[data[9]] || String(data[9])) : null;
    const matName = data[10] || data[52] || null; // materialName or abbreviation
    const brand   = data[11] || null;
    const weight  = data[16] ?? data[17] ?? null; // nominal or actual net weight (g)

    // Primary color (key 19): likely array [r, g, b] or map {0:r,1:g,2:b}
    let hex = null;
    const cd = data[19];
    if (cd) {
      let r, g, b;
      if (Array.isArray(cd) && cd.length >= 3)      { [r, g, b] = cd; }
      else if (typeof cd === 'object' && !Array.isArray(cd)) { r = cd[0]; g = cd[1]; b = cd[2]; }
      if (r !== undefined && g !== undefined && b !== undefined) {
        hex = '#' + [r, g, b].map(x => Math.round(x).toString(16).padStart(2, '0')).join('');
      }
    }

    const material = matType || matName;
    if (!material && !brand) return null;

    // Every one of these is a temperature, a time or a weight. CBOR can carry a
    // TEXT STRING under any key, and these went into the result untouched and from
    // there straight into innerHTML — so a crafted tag put markup on the panel.
    // The app's CSP (script-src 'self', img-src 'self' data: blob:) stops it
    // running script or fetching anything, but injected markup can still add
    // controls the delegated [data-act] handler will act on, which is exactly the
    // hole the G-code thumbnail had. A number that is not a number is not data.
    const num = (v) => (Number.isFinite(+v) ? +v : null);
    return {
      standard:    'OpenPrintTag',
      manufacturer: brand,
      material:    matType || matName,
      colorName:   null,
      hex,
      weight:      Number.isFinite(+weight) && +weight ? Math.round(+weight) : null,
      minPrint:    num(data[34]), maxPrint: num(data[35]),
      minBed:      num(data[37]), maxBed:   num(data[38]),
      dryTemp:     num(data[57]), dryTime:  num(data[58]) // dryTime in minutes
    };
  } catch { return null; }
}

// ── NDEF TLV unwrapper ─────────────────────────────────────────────────────
// Handles raw NTAG213 memory dump (starts with 0x04) or bare NDEF message
function _extractNDEFPayload(bytes, mimeType) {
  let pos = 0;
  // If this looks like a full NTAG213 dump (serial starts 04), skip 16-byte UID/config header
  if (bytes.length > 16 && bytes[0] === 0x04) pos = 16;

  // Find NDEF TLV (0x03)
  while (pos < bytes.length - 2) {
    const t = bytes[pos];
    if (t === 0xFE) break; // Terminator
    if (t === 0x00) { pos++; continue; } // Null TLV
    let len, dataStart;
    if (bytes[pos + 1] === 0xFF) { len = ((bytes[pos + 2] << 8) | bytes[pos + 3]) >>> 0; dataStart = pos + 4; }
    else                          { len = bytes[pos + 1];                                dataStart = pos + 2; }
    len = Math.min(len, Math.max(0, bytes.length - dataStart));
    const tlv = bytes.slice(dataStart, dataStart + len);
    pos = dataStart + len;

    if (t === 0x03) {
      // Parse NDEF records within this TLV
      let p = 0;
      while (p < tlv.length) {
        const flags = tlv[p]; p++;
        const tnf = flags & 0x07;
        if (p + 2 > tlv.length) break;
        const typeLen    = tlv[p++];
        const sr         = !!(flags & 0x10);
        let payloadLen;
        if (sr) { payloadLen = tlv[p++]; }
        else    { payloadLen = ((tlv[p]<<24)|(tlv[p+1]<<16)|(tlv[p+2]<<8)|tlv[p+3]) >>> 0; p += 4; }
        const il = !!(flags & 0x08);
        let idLen = 0;
        if (il) { idLen = tlv[p++]; }
        if (payloadLen > tlv.length || typeLen > tlv.length) break; // malformed/overrun guard
        const recType   = new TextDecoder().decode(tlv.slice(p, p + typeLen)); p += typeLen;
        p += idLen;
        const payload   = tlv.slice(p, p + payloadLen); p += payloadLen;
        if (tnf === 0x02 && recType === mimeType) return payload;
        if (flags & 0x40) break; // ME bit — last record
      }
    }
  }
  return null;
}

// ── Main NFC hex entry point ───────────────────────────────────────────────
function parseNFCHex(hexStr) {
  const clean = hexStr.replace(/[^0-9a-fA-F]/g, '');
  if (clean.length > 16384) return { error: 'That is too large to be an NFC tag dump — paste only the tag memory.' };
  if (clean.length < 20) return { error: t('scan.hex_too_short') || 'Too short — paste the full NFC memory dump from your reader app.' };
  if (clean.length % 2 !== 0) return { error: 'Odd number of hex characters — check the dump.' };
  const bytes = new Uint8Array(clean.match(/../g).map(h => parseInt(h, 16)));

  // 1. Try NDEF-wrapped OpenTag3D
  const ot3dPayload = _extractNDEFPayload(bytes, 'application/opentag3d');
  if (ot3dPayload) { const r = parseOpenTag3DBytes(ot3dPayload); if (r) return r; }

  // 2. Try NDEF-wrapped OpenPrintTag (Prusa)
  const optPayload = _extractNDEFPayload(bytes, 'application/vnd.openprinttag');
  if (optPayload) { const r = parseOpenPrintTagCBOR(optPayload); if (r) return r; }

  // 3. Try raw OpenTag3D binary (no NDEF wrapper)
  const raw = parseOpenTag3DBytes(bytes);
  if (raw) return raw;

  return { error: t('scan.hex_no_parse') || 'Could not parse as OpenTag3D or OpenPrintTag. Make sure you paste the raw memory dump (not just the NDEF text).' };
}

// ── Filament scanner (camera + BarcodeDetector) ── */

/** Route a Khayt label code (KHAYT-SPOOL / KHAYT-ORDER / tracking URL) to the
 *  right record. Returns true if it was a Khayt code (handled), false otherwise
 *  so the caller can fall back to filament parsing. */
function routeKhaytScan(raw) {
  if (typeof KhaytScan === 'undefined') return false;
  const scan = KhaytScan.parseScanCode(raw);
  if (scan.type !== 'spool' && scan.type !== 'order' && scan.type !== 'track') return false;
  // Close the scanner modal, then open the target.
  document.querySelector('#modalMount [data-act="cancel"]')?.click();
  if (scan.type === 'spool') {
    if ((inventory || []).some((i) => i.id === scan.id)) openInventoryEditor(scan.id);
    else toast(t('scan.spool_missing') || 'That spool is not in your inventory.', 'error');
  } else {
    const order = scan.type === 'order'
      ? (printLog || []).find((o) => o.id === scan.id)
      : (printLog || []).find((o) => o.trackingToken === scan.token);
    if (order && typeof openOrderEditor === 'function') openOrderEditor(order.id);
    else toast(t('scan.order_missing') || 'That order was not found.', 'error');
  }
  return true;
}

function parseFilamentFromText(text) {
  // Extract material type (check compound types first)
  const materialMap = [
    ['PLA-CF',  /pla[\s\-]?cf\b/i],
    ['PETG-CF', /petg[\s\-]?cf\b/i],
    ['PA-CF',   /pa[\s\-]?cf\b|nylon[\s\-]?cf\b/i],
    ['PETG',    /\bpetg\b/i],
    ['TPU',     /\btpu\b|\btpe\b/i],
    ['ASA',     /\basa\b/i],
    ['ABS',     /\babs\b/i],
    ['Nylon',   /\bnylon\b|\bpa\s*\d/i],
    ['HIPS',    /\bhips\b/i],
    ['PVA',     /\bpva\b/i],
    ['PLA',     /\bpla\b/i],
  ];
  let detectedType = null;
  for (const [type, re] of materialMap) {
    if (re.test(text)) { detectedType = type; break; }
  }

  // Extract brand
  const brandMap = [
    ['Bambu Lab',  /bambu/i],
    ['eSun',       /esun/i],
    ['Polymaker',  /polymaker/i],
    ['Creality',   /creality/i],
    ['SUNLU',      /sunlu/i],
    ['Prusament',  /prusament|prusa/i],
    ['Hatchbox',   /hatchbox/i],
    ['Overture',   /overture/i],
  ];
  let detectedBrand = null;
  for (const [brand, re] of brandMap) {
    if (re.test(text)) { detectedBrand = brand; break; }
  }

  // Extract color keywords
  const colorMap = [
    ['White',   /\bwhite\b|\bأبيض\b/i],
    ['Black',   /\bblack\b|\bأسود\b/i],
    ['Red',     /\bred\b|\bأحمر\b/i],
    ['Orange',  /\borange\b|\bبرتقالي\b/i],
    ['Yellow',  /\byellow\b|\bأصفر\b/i],
    ['Green',   /\bgreen\b|\bأخضر\b/i],
    ['Blue',    /\bblue\b|\bأزرق\b/i],
    ['Purple',  /\bpurple\b|\bviolet\b|\bبنفسجي\b/i],
    ['Pink',    /\bpink\b|\bوردي\b/i],
    ['Gray',    /\bgray\b|\bgrey\b|\bرمادي\b/i],
    ['Brown',   /\bbrown\b|\bبني\b/i],
    ['Gold',    /\bgold\b|\bذهبي\b/i],
    ['Silver',  /\bsilver\b|\bفضي\b/i],
    ['Copper',  /\bcopper\b|\bنحاسي\b/i],
    ['Clear',   /\bclear\b|\btransparent\b|\bشفاف\b/i],
    ['Natural', /\bnatural\b|\bطبيعي\b/i],
  ];
  let detectedColor = null;
  for (const [color, re] of colorMap) {
    if (re.test(text)) { detectedColor = color; break; }
  }

  return { type: detectedType, brand: detectedBrand, color: detectedColor };
}

function scoreFil(f, parsed) {
  let score = 0;
  if (parsed.brand && f.brand === parsed.brand) score += 10;
  if (parsed.type  && f.type  === parsed.type)  score += 8;
  if (parsed.color && f.color.toLowerCase().includes(parsed.color.toLowerCase())) score += 5;
  return score;
}

async function openFilamentScanner() {
  const hasBarcodeDetector = 'BarcodeDetector' in window;
  const hasCamera = !!navigator.mediaDevices?.getUserMedia;

  const bodyHtml = `
    <!-- Mode toggle -->
    <div style="display:flex; gap:6px; margin-bottom:14px;">
      <button id="scanModeCamera" class="btn small primary" style="flex:1;">${escapeHtml(t('scan.mode_camera') || '📷 Camera Scan')}</button>
      <button id="scanModeNFC"    class="btn ghost small"  style="flex:1;">${escapeHtml(t('scan.mode_nfc')    || '📋 Paste NFC Dump')}</button>
    </div>

    <!-- ── Camera panel ── -->
    <div id="scanPanelCamera">
      <div style="position:relative; display:inline-block; width:100%;">
        <video id="scanVideo" autoplay playsinline muted
          style="width:100%; max-height:280px; border-radius:var(--radius); background:#000; display:block;"></video>
        <div style="position:absolute;inset:0;pointer-events:none;border-radius:var(--radius);box-shadow:inset 0 0 0 3px rgba(91,156,240,0.4);"></div>
        <div style="position:absolute;inset:20%;pointer-events:none;">
          <div style="position:absolute;top:0;left:0;width:20px;height:20px;border-top:3px solid var(--primary);border-left:3px solid var(--primary);border-radius:2px 0 0 0;"></div>
          <div style="position:absolute;top:0;right:0;width:20px;height:20px;border-top:3px solid var(--primary);border-right:3px solid var(--primary);border-radius:0 2px 0 0;"></div>
          <div style="position:absolute;bottom:0;left:0;width:20px;height:20px;border-bottom:3px solid var(--primary);border-left:3px solid var(--primary);border-radius:0 0 0 2px;"></div>
          <div style="position:absolute;bottom:0;right:0;width:20px;height:20px;border-bottom:3px solid var(--primary);border-right:3px solid var(--primary);border-radius:0 0 2px 0;"></div>
        </div>
      </div>
      <p id="scanStatus" style="margin:8px 0 4px; font-size:12.5px; color:var(--text-muted); text-align:center;">
        ${escapeHtml(t('scan.aim') || 'Point camera at the QR code or barcode on the spool…')}
      </p>
      <div id="scanResultCamera" style="display:none; margin-top:10px; padding:14px; background:var(--surface-2); border:1px solid var(--primary); border-radius:var(--radius); text-align:left;"></div>
      <div style="display:flex; gap:6px; margin-top:12px;">
        <input id="scanManual" type="text" autocomplete="off" placeholder="${escapeHtml(t('scan.manual_ph') || 'or scan / type a code (spool · order)')}"
          style="flex:1; padding:8px 10px; border-radius:var(--radius-sm); border:1px solid var(--border); background:var(--surface-2); color:var(--text); font-size:13px;">
        <button class="btn small primary" id="scanManualGo">${escapeHtml(t('scan.go') || 'Go')}</button>
      </div>
      <p style="font-size:11px; color:var(--text-muted); margin-top:5px;">${escapeHtml(t('scan.manual_hint') || 'Works with a USB/Bluetooth barcode scanner, or scan a Khayt label QR with the camera.')}</p>
    </div>

    <!-- ── NFC paste panel ── -->
    <div id="scanPanelNFC" style="display:none;">
      <p style="font-size:12.5px; color:var(--text-dim); margin-bottom:10px;">
        ${escapeHtml(t('scan.nfc_paste_hint') || 'Use an NFC reader app on your phone (e.g. NFC Tools) to read the spool tag, then copy the raw hex dump and paste it here.')}
      </p>
      <textarea id="scanHexInput" rows="6" style="width:100%; font-family:monospace; font-size:11px; padding:8px;
        border-radius:var(--radius-sm); border:1px solid var(--border); background:var(--surface-2); color:var(--text);
        resize:vertical;" placeholder="04 A1 B2 C3 D4 E5 F6 07 …&#10;(raw hex dump from NFC Tools or similar)"></textarea>
      <div style="display:flex; gap:8px; margin-top:8px; align-items:center;">
        <button class="btn small primary" id="btnParseHex">${escapeHtml(t('scan.parse_hex') || 'Parse NFC Data')}</button>
        <span style="font-size:11px; color:var(--text-muted);">
          ${escapeHtml(t('scan.nfc_standards') || 'Supports: OpenTag3D · OpenPrintTag (Prusa)')}
        </span>
      </div>
      <div id="scanResultNFC" style="display:none; margin-top:12px; padding:14px; background:var(--surface-2); border:1px solid var(--primary); border-radius:var(--radius);"></div>

      <div style="margin-top:14px; padding:10px 12px; background:rgba(91,156,240,0.06);
        border:1px solid rgba(91,156,240,0.2); border-radius:var(--radius-sm); font-size:11.5px; color:var(--text-muted);">
        <strong style="color:var(--primary);">iOS (coming soon):</strong>
        ${escapeHtml(t('scan.nfc_ios_note') || 'The iOS version will read NFC tags automatically — just tap the spool. Both OpenTag3D and OpenPrintTag (Prusa) are fully supported.')}
      </div>
    </div>
  `;

  openFormModal({
    title: t('scan.title') || 'Scan Filament Label',
    bodyHtml,
    noSave: true,
    onMount() {
      // ── manual / USB-scanner code entry (USB scanners "type" + Enter) ──────
      const manual = document.getElementById('scanManual');
      const submitManual = () => {
        const v = (manual && manual.value || '').trim();
        if (!v) return;
        if (routeKhaytScan(v)) return; // spool / order / tracking code
        // Otherwise treat it as filament text and show matches.
        const parsed = parseFilamentFromText(v);
        const scored = (filamentsDB || []).map((f) => ({ ...f, _score: scoreFil(f, parsed) })).filter((f) => f._score > 0).sort((a, b) => b._score - a._score);
        if (typeof showCameraMatch === 'function') showCameraMatch(v, parsed, scored);
      };
      if (manual) {
        manual.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); submitManual(); } });
        setTimeout(() => manual.focus(), 60);
      }
      document.getElementById('scanManualGo')?.addEventListener('click', submitManual);

      // ── shared: apply NFC/OpenTag result to form ──────────────────────────
      function applyNFCResult(nfcData, resultEl) {
        if (nfcData.error) {
          resultEl.style.display = 'block';
          resultEl.innerHTML = `<div style="color:var(--danger); font-size:12.5px;">${_iIcoL('alert', '⚠', 12)}${escapeHtml(nfcData.error)}</div>`;
          return;
        }

        const colorDot = nfcData.hex
          ? `<span style="display:inline-block;width:22px;height:22px;border-radius:50%;background:${safeCssColor(nfcData.hex)};border:2px solid rgba(255,255,255,0.2);vertical-align:middle;margin-inline-end:8px;"></span>`
          : '';
        const stdBadge = `<span style="font-size:10px;padding:2px 7px;border-radius:20px;background:rgba(91,156,240,0.18);color:var(--primary);font-weight:600;">${escapeHtml(nfcData.standard)}</span>`;

        // The parsers coerce these to numbers, and this escapes them anyway: the
        // panel is built from a stranger's tag, and one parser forgetting a
        // coercion should not be enough to put markup on the screen.
        const metaRows = [];
        const n = (v) => escapeHtml(String(v));
        if (nfcData.weight)    metaRows.push(`${escapeHtml(t('inv.weight')||'Weight')}: <strong>${n(nfcData.weight)} g</strong>`);
        if (nfcData.printTemp) metaRows.push(`Print: <strong>${n(nfcData.printTemp)}°C</strong>`);
        if (nfcData.minPrint && nfcData.maxPrint) metaRows.push(`Print range: <strong>${n(nfcData.minPrint)}–${n(nfcData.maxPrint)}°C</strong>`);
        if (nfcData.bedTemp)   metaRows.push(`Bed: <strong>${n(nfcData.bedTemp)}°C</strong>`);
        if (nfcData.minBed && nfcData.maxBed)     metaRows.push(`Bed range: <strong>${n(nfcData.minBed)}–${n(nfcData.maxBed)}°C</strong>`);
        if (nfcData.dryTemp)   metaRows.push(`Dry: <strong>${n(nfcData.dryTemp)}°C${nfcData.dryTime ? ' × ' + n(nfcData.dryTime) + ' h' : ''}</strong>`);
        if (nfcData.density)   metaRows.push(`Density: <strong>${n(nfcData.density)} g/cm³</strong>`);

        resultEl.style.display = 'block';
        resultEl.innerHTML = `
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;flex-wrap:wrap;">
            ${colorDot}
            <div style="flex:1;">
              <div style="font-weight:600;font-size:13px;">${escapeHtml(nfcData.colorName || nfcData.material || '—')}</div>
              <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(nfcData.manufacturer||'')} · ${escapeHtml(nfcData.material||'')} ${stdBadge}</div>
            </div>
            <button class="btn small primary" id="btnUseNFC">${escapeHtml(t('scan.use')||'Use this')}</button>
          </div>
          ${metaRows.length ? `<div style="font-size:11px;color:var(--text-dim);display:flex;flex-wrap:wrap;gap:8px 16px;">${metaRows.map(r=>`<span>${r}</span>`).join('')}</div>` : ''}`;

        document.getElementById('btnUseNFC').addEventListener('click', () => {
          const parts = [nfcData.manufacturer, nfcData.material, nfcData.colorName].filter(Boolean);
          $('#invMaterial').value = parts.join(' – ') || nfcData.material || '';
          if (nfcData.hex)    setInvColor(nfcData.hex);
          if (nfcData.weight) $('#invWeight').value = nfcData.weight;
          $('#modalMount').innerHTML = '';
          toast(t('inv.catalog_picked') || 'Filament imported from NFC tag', 'success', 2000);
        });
      }

      // ── mode toggle ───────────────────────────────────────────────────────
      let stream = null, scanTimer = null, cameraRunning = false;

      function stopCamera() {
        clearInterval(scanTimer); scanTimer = null;
        if (stream) { stream.getTracks().forEach(t => t.stop()); stream = null; }
        cameraRunning = false;
      }

      document.getElementById('scanModeCamera').addEventListener('click', () => {
        document.getElementById('scanModeCamera').className = 'btn small primary';
        document.getElementById('scanModeNFC').className    = 'btn ghost small';
        document.getElementById('scanPanelCamera').style.display = '';
        document.getElementById('scanPanelNFC').style.display    = 'none';
        if (!cameraRunning) startCamera();
      });

      document.getElementById('scanModeNFC').addEventListener('click', () => {
        document.getElementById('scanModeNFC').className    = 'btn small primary';
        document.getElementById('scanModeCamera').className = 'btn ghost small';
        document.getElementById('scanPanelNFC').style.display    = '';
        document.getElementById('scanPanelCamera').style.display = 'none';
        stopCamera();
      });

      // ── NFC paste panel ───────────────────────────────────────────────────
      document.getElementById('btnParseHex').addEventListener('click', () => {
        const hex = document.getElementById('scanHexInput').value.trim();
        const result = parseNFCHex(hex);
        applyNFCResult(result, document.getElementById('scanResultNFC'));
      });

      // ── Camera panel ──────────────────────────────────────────────────────
      const video   = document.getElementById('scanVideo');
      const status  = document.getElementById('scanStatus');
      const resultC = document.getElementById('scanResultCamera');
      let done = false;

      // Stop camera when modal closes (disconnect observer immediately after firing)
      const _scanObserver = new MutationObserver(() => {
        if (!document.getElementById('scanVideo')) { stopCamera(); _scanObserver.disconnect(); }
      });
      _scanObserver.observe(document.getElementById('modalMount'), { childList: true, subtree: false });

      function showCameraMatch(rawText, parsed, matches) {
        done = true; stopCamera(); video.style.opacity = '0.4';
        if (matches.length) {
          const top = matches[0];
          resultC.style.display = 'block';
          resultC.innerHTML = `
            <div style="display:flex;align-items:center;gap:10px;margin-bottom:8px;">
              <span style="width:26px;height:26px;border-radius:50%;background:${safeCssColor(top.hex)};border:2px solid rgba(255,255,255,0.2);flex-shrink:0;"></span>
              <div style="flex:1;">
                <div style="font-weight:600;font-size:13px;">${escapeHtml(top.color)}</div>
                <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(top.brand)} · ${escapeHtml(top.line)} · ${escapeHtml(top.type)}</div>
              </div>
              <button class="btn small primary" id="btnUseScan">${escapeHtml(t('scan.use')||'Use this')}</button>
            </div>
            ${matches.length > 1 ? `<div style="font-size:11px;color:var(--text-muted);margin-bottom:5px;">${escapeHtml(t('scan.other_matches')||'Other matches:')}</div>
            <div style="display:flex;flex-wrap:wrap;gap:6px;">${matches.slice(1,6).map((m,i)=>`
              <button class="btn ghost small scan-alt" data-idx="${i+1}" style="display:flex;align-items:center;gap:5px;font-size:11px;">
                <span style="width:10px;height:10px;border-radius:50%;background:${safeCssColor(m.hex)};flex-shrink:0;"></span>
                ${escapeHtml(m.color)} (${escapeHtml(m.type)})</button>`).join('')}</div>` : ''}
            <div style="margin-top:8px;font-size:10.5px;color:var(--text-muted);">
              ${escapeHtml(t('scan.raw')||'Scanned:')} <code>${escapeHtml(rawText.slice(0,80))}</code></div>`;

          document.getElementById('btnUseScan').addEventListener('click', () => {
            $('#invMaterial').value = `${top.brand} ${top.line} – ${top.color}`;
            setInvColor(top.hex);
            $('#modalMount').innerHTML = '';
            toast(t('inv.catalog_picked')||`${top.color} selected`, 'success', 1800);
          });
          resultC.querySelectorAll('.scan-alt').forEach(btn => {
            btn.addEventListener('click', () => {
              const m2 = matches[+btn.dataset.idx];
              $('#invMaterial').value = `${m2.brand} ${m2.line} – ${m2.color}`;
              setInvColor(m2.hex);
              $('#modalMount').innerHTML = '';
              toast(t('inv.catalog_picked')||`${m2.color} selected`, 'success', 1800);
            });
          });
        } else {
          resultC.style.display = 'block';
          resultC.innerHTML = `
            <div style="font-size:12px;color:var(--text-dim);margin-bottom:8px;">${escapeHtml(t('scan.no_match')||'Not found in catalog:')}</div>
            <code style="font-size:11px;word-break:break-all;">${escapeHtml(rawText.slice(0,200))}</code>
            <div style="display:flex;gap:8px;margin-top:10px;">
              <button class="btn small primary" id="btnScanManual">${escapeHtml(t('scan.fill_manual')||'Fill from text')}</button>
              <button class="btn ghost small"   id="btnScanRetry">${escapeHtml(t('scan.retry')||'Scan again')}</button>
            </div>`;
          document.getElementById('btnScanManual').addEventListener('click', () => {
            $('#invMaterial').value = [parsed.brand, parsed.type, parsed.color].filter(Boolean).join(' ') || rawText.slice(0, 80);
            $('#modalMount').innerHTML = '';
          });
          document.getElementById('btnScanRetry').addEventListener('click', () => {
            done = false; resultC.style.display = 'none'; video.style.opacity = '1';
            status.textContent = t('scan.aim') || 'Point camera…'; status.style.color = 'var(--text-muted)';
            startCamera();
          });
        }
      }

      function startCamera() {
        if (!hasCamera) {
          status.textContent = t('scan.no_camera') || 'Camera not available';
          status.style.color = 'var(--danger)'; return;
        }
        navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment', width: { ideal: 1280 } } })
          .then(s => { stream = s; video.srcObject = s; cameraRunning = true; })
          .catch(() => {
            status.textContent = t('scan.camera_error') || 'Could not access camera.';
            status.style.color = 'var(--danger)';
          });
      }

      function startScanning() {
        if (!hasBarcodeDetector) {
          status.textContent = t('scan.no_detector') || 'Live barcode detection not supported.'; return;
        }
        const detector = new BarcodeDetector({ formats: ['qr_code','code_128','ean_13','data_matrix','aztec','pdf417'] });
        scanTimer = setInterval(async () => {
          if (done || video.readyState < 2) return;
          try {
            const codes = await detector.detect(video);
            if (codes.length > 0) {
              clearInterval(scanTimer);
              status.textContent = `✓ ${t('scan.detected')||'Code detected!'}`;
              status.style.color = 'var(--success, #22c55e)';
              const raw    = codes[0].rawValue;
              // A Khayt label QR (spool/order) routes straight to that record.
              if (routeKhaytScan(raw)) return;
              const parsed = parseFilamentFromText(raw);
              const scored = (filamentsDB || []).map(f => ({ ...f, _score: scoreFil(f, parsed) })).filter(f => f._score > 0).sort((a,b) => b._score - a._score);
              showCameraMatch(raw, parsed, scored);
            }
          } catch { /* frame not ready */ }
        }, 400);
      }

      video.addEventListener('loadeddata', startScanning);
      startCamera();
    }
  });
}

function addInventoryItem() {
  // The record is lib/spool-edit.js's, so the Mac app writes the same one.
  const made = SpoolEdit.newSpool({
    material:     $('#invMaterial').value,
    cost:         $('#invCost').value,
    weight:       $('#invWeight').value,
    color:        $('#invColor').value,
    materialType: $('#invMaterialType')?.value,
    lot:          $('#invLot')?.value,
    locationId:   $('#invLocation')?.value,
  }, {
    id: uid('INV'),
    today: localDateStr(),
    // Per-location: tag the spool with the branch being looked at when the
    // form did not name one.
    activeLocation: (typeof activeLocation !== 'undefined') ? activeLocation : null,
  });
  if (made.refused) { toast(t('inv.material_ph'), 'error'); return; }
  inventory.push(made.spool);
  saveAll();
  renderInventory();
  $('#invMaterial').value = '';
  if ($('#invLot')) $('#invLot').value = '';
  toast(t('inv.added'), 'success');
}


async function deleteInventoryItem(id) {
  const item = inventory.find(i => i.id === id);
  const label = item ? `${item.material || ''} ${item.color || ''}`.trim() : id;
  const ok = await confirmModal(`${t('common.delete')} "${label}"?`, { danger: true });
  if (!ok) return;
  const idx = inventory.findIndex(i => i.id === id);
  const removed = idx >= 0 ? inventory[idx] : null;
  inventory = inventory.filter(i => i.id !== id);
  saveAll();
  renderInventory();
  toast(t('inv.removed'), 'success', 5000, removed ? {
    undo: () => {
      inventory.splice(Math.min(Math.max(idx, 0), inventory.length), 0, removed);
      saveAll();
      renderInventory();
    },
  } : {});
}

function openInventoryEditor(id) {
  const item = inventory.find(i => i.id === id);
  if (!item) return;

  const priceHistory = item.priceHistory || [];
  const histHtml = priceHistory.length > 0 ? `
    <div style="margin-top:14px; padding-top:12px; border-top:1px solid var(--border-soft);">
      <label style="margin-top:0;">${escapeHtml(t('inv.price_history'))}</label>
      <div class="price-history-list">
        ${priceHistory.slice(-6).reverse().map(h => `
          <div class="price-history-row">
            <span class="ph-date">${escapeHtml(h.date)}</span>
            <span class="ph-cost">${fmtPrice(h.cost)}</span>
          </div>`).join('')}
      </div>
    </div>` : '';

  const existingColours = (settings.filamentColours || {})[item.material] || [];

  const bodyHtml = `
    <div class="inline-pair" style="align-items:end;">
      <div>
        <label>${escapeHtml(t('inv.material'))}</label>
        <input type="text" id="ieMatInput" value="${escapeHtml(item.material)}" placeholder="${escapeHtml(t('inv.material_ph'))}">
      </div>
      <div>
        <label>${escapeHtml(t('inv.material_type'))}</label>
        <select id="ieMaterialType">
          <option value="fdm"${(item.materialType || 'fdm') === 'fdm' ? ' selected' : ''}>${escapeHtml(t('inv.type_fdm'))}</option>
          <option value="resin"${item.materialType === 'resin' ? ' selected' : ''}>${escapeHtml(t('inv.type_resin'))}</option>
          <option value="other"${item.materialType === 'other' ? ' selected' : ''}>${escapeHtml(t('inv.type_other'))}</option>
        </select>
      </div>
    </div>
    <div class="inline-pair" style="align-items:end; margin-top:14px;">
      <div>
        <label>${escapeHtml(t('inv.colour_variant'))}</label>
        <input type="text" id="ieColourInput" list="ieColourDL" value="${escapeHtml(item.colourVariant || '')}" placeholder="${escapeHtml(t('inv.colour_variant_ph'))}">
        <datalist id="ieColourDL">${existingColours.map(c => `<option value="${escapeHtml(c)}">`).join('')}</datalist>
      </div>
      <div>
        <label>${escapeHtml(t('inv.color'))}</label>
        <div style="display:flex; gap:6px; align-items:center;">
          <input type="color" id="ieColorInput" value="${escapeHtml(item.color || '#888888')}" style="width:46px; height:38px; padding:3px 4px; border-radius:var(--radius-sm); border:1px solid var(--border); cursor:pointer; background:var(--bg-elev); flex-shrink:0;"
            oninput="var h=document.getElementById('ieColorHex'); if(h) h.value=this.value.toUpperCase();">
          <input type="text" id="ieColorHex" value="${escapeHtml((item.color || '#888888').toUpperCase())}" spellcheck="false" maxlength="7" aria-label="Hex" style="flex:1; min-width:0; font-family:ui-monospace,Menlo,monospace; text-transform:uppercase; height:38px; padding:0 8px; border-radius:var(--radius-sm); border:1px solid var(--border); background:var(--surface-2); color:var(--text); font-size:13px;"
            oninput="var v=this.value.trim(); if(/^#?[0-9a-fA-F]{6}$/.test(v)){ if(v[0]!=='#') v='#'+v; document.getElementById('ieColorInput').value=v; }">
        </div>
      </div>
    </div>
    <label style="margin-top:14px;" id="ieCostLabel">${escapeHtml(t('inv.cost'))}</label>
    <input type="number" id="ieCostInput" value="${item.cost}" min="0" step="0.01">
    <label style="margin-top:14px;" id="ieWeightLabel">${escapeHtml(t(item.materialType === 'resin' ? 'inv.volume_ml' : 'inv.remaining'))}</label>
    <input type="number" id="ieWeightInput" value="${Math.round(item.weight)}" min="0" step="1">
    <div class="inline-pair" style="margin-top:14px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('inv.purchased_on'))}</label>
        <input type="date" id="iePurchasedAt" value="${escapeHtml(item.purchasedAt || '')}">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('inv.opened_on'))}</label>
        <input type="date" id="ieOpenedAt" value="${escapeHtml(item.openedAt || '')}">
      </div>
    </div>
    <div class="inline-pair" style="margin-top:14px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('inv.lot') || 'Lot / Batch')}</label>
        <input type="text" id="ieLot" value="${escapeHtml(item.lot || '')}" placeholder="${escapeHtml(t('inv.lot_ph') || 'e.g. 2024-Q1-A')}">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('inv.location_branch') || 'Location / Branch')}</label>
        <select id="ieLocation">
          <option value="">${escapeHtml(t('inv.location_unassigned') || 'Unassigned')}</option>
          ${(typeof locations !== 'undefined' ? locations : []).map(l => `<option value="${escapeHtml(l.id)}"${item.locationId === l.id ? ' selected' : ''}>${escapeHtml(l.name)}</option>`).join('')}
        </select>
      </div>
    </div>
    <div class="inline-pair" style="margin-top:14px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('inv.reorder_point'))}</label>
        <input type="number" id="ieReorderPoint" value="${item.reorderPoint ?? 200}" min="0" step="1" placeholder="200">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('inv.reorder_qty'))}</label>
        <input type="number" id="ieReorderQty" value="${item.reorderQty ?? 1000}" min="0" step="1" placeholder="1000">
      </div>
    </div>
    <div style="margin-top:14px; padding:10px 12px; background:rgba(255,255,255,0.04); border-radius:var(--radius-sm); border:1px solid var(--border-soft);">
      <label style="margin-top:0; font-size:12px; font-weight:600;">${_iIcoL('thermo', '🌡')}${escapeHtml(t('inv.print_settings'))}</label>
      <div class="inline-pair" style="margin-top:8px;">
        <div>
          <label style="margin-top:0; font-size:11.5px;">${escapeHtml(t('inv.print_temp'))}</label>
          <input type="number" id="iePrintTemp" value="${item.printTemp || ''}" min="0" step="1" placeholder="e.g. 215">
        </div>
        <div>
          <label style="margin-top:0; font-size:11.5px;">${escapeHtml(t('inv.bed_temp'))}</label>
          <input type="number" id="ieBedTemp" value="${item.bedTemp || ''}" min="0" step="1" placeholder="e.g. 60">
        </div>
        <div>
          <label style="margin-top:0; font-size:11.5px;">${escapeHtml(t('inv.max_speed'))}</label>
          <input type="number" id="ieMaxSpeed" value="${item.maxSpeed || ''}" min="0" step="1" placeholder="e.g. 200">
        </div>
      </div>
    </div>
    ${histHtml}
  `;

  openFormModal({
    title: t('inv.edit_title'),
    saveLabel: t('common.save'),
    bodyHtml,
    onSave() {
      // The rule is lib/spool-edit.js: the same clamps, the same "a blank
      // optional field is absent", the same price history when the cost moves,
      // and the same colour added to the shop's library. It was fifty lines
      // here, which is why only this window could correct a spool.
      const el = (id) => document.getElementById(id);
      const out = SpoolEdit.applyEdit(item, {
        material:     el('ieMatInput').value,
        color:        el('ieColorInput').value,
        materialType: el('ieMaterialType')?.value,
        colourVariant: el('ieColourInput')?.value,
        cost:         el('ieCostInput').value,
        weight:       el('ieWeightInput').value,
        purchasedAt:  el('iePurchasedAt').value,
        openedAt:     el('ieOpenedAt').value,
        lot:          el('ieLot')?.value,
        locationId:   el('ieLocation')?.value,
        printTemp:    el('iePrintTemp').value,
        bedTemp:      el('ieBedTemp').value,
        maxSpeed:     el('ieMaxSpeed').value,
        reorderPoint: el('ieReorderPoint')?.value,
        reorderQty:   el('ieReorderQty')?.value,
      }, { today: localDateStr(), settings });
      if (out.refused) { toast(t('inv.material_ph'), 'error'); return false; }
      saveAll();
      renderInventory();
      toast(t('inv.updated'), 'success');
      return true;
    }
  });
}

/* New Feature 6: Price history modal */
function openPriceHistory(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const history = (item.priceHistory || []).slice().reverse(); // newest first
  if (history.length === 0) {
    toast(t('inv.price_hist_empty'), 'info');
    return;
  }
  const rows = history.map((h, i) => {
    const prev = history[i + 1];
    let changePct = '';
    if (prev && prev.cost > 0) {
      const diff = ((h.cost - prev.cost) / prev.cost * 100).toFixed(1);
      const arrow = +diff > 0 ? '▲' : (+diff < 0 ? '▼' : '—');
      const color = +diff > 0 ? 'var(--danger)' : (+diff < 0 ? 'var(--success)' : 'var(--text-muted)');
      changePct = `<span style="color:${color}; font-weight:600;">${arrow} ${Math.abs(+diff)}%</span>`;
    }
    return `<tr>
      <td style="font-size:12px; color:var(--text-muted);">${escapeHtml(h.date || '')}</td>
      <td style="font-weight:600;">${fmtPrice(h.cost)}</td>
      <td>${changePct}</td>
    </tr>`;
  });
  // Add current cost as the most recent entry
  const currentRow = `<tr style="background:rgba(91,156,240,0.08);">
    <td style="font-size:12px; color:var(--primary); font-weight:600;">${escapeHtml(t('inv.current_stock'))}</td>
    <td style="font-weight:700; color:var(--primary);">${fmtPrice(item.cost)}</td>
    <td></td>
  </tr>`;

  openFormModal({
    title: `${t('inv.price_history')} — ${escapeHtml(item.material)}`,
    noSave: true,
    bodyHtml: `
      <div class="table-wrap">
        <table class="price-history-table">
          <thead><tr>
            <th>${escapeHtml(t('common.date'))}</th>
            <th>${escapeHtml(t('inv.cost'))}</th>
            <th>${escapeHtml(t('inv.price_change'))}</th>
          </tr></thead>
          <tbody>${currentRow}${rows.join('')}</tbody>
        </table>
      </div>`,
  });
}

function getQueuedWeight(itemId) {
  return printLog
    .filter(o => o.status !== 'completed' && o.status !== 'quote' && !o.archived)
    .reduce((s, o) =>
      s + (o.parts || [])
        .filter(p => p.filamentId === itemId)
        // Supports are real filament off the same spool. Omitting them here — while
        // partGramsConsumed(), which does the actual deduction, includes them — meant the
        // "queued grams" badge under-reserved stock on support-heavy jobs.
        .reduce((ps, p) => ps + ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1), 0)
    , 0);
}

// Feature 3: Compute grams reserved for a specific spool across active orders
// Grams a part consumes. MUST mirror deductFilamentForOrder (print + support,
// times quantity) so reservation, over-commit, and forecast never under-count
// relative to the actual completion deduction.
function partGramsConsumed(p) {
  return Deduction().partGramsConsumed(p);
}

// Grams THIS part draws from one specific spool id. For a multicolour part the
// grams are split across the assigned colour filaments (× qty); for a normal part
// it's the whole part when the spool matches its chosen spool/filament, else 0.
function partGramsForSpool(p, spoolId) {
  if (p && p.colours && p.colours.length) {
    const q = +p.qty || 1;
    return p.colours.filter(c => c.filamentId === spoolId)
      .reduce((s, c) => s + (+c.grams || 0) * q, 0);
  }
  return ((p.spoolId || p.filamentId) === spoolId) ? partGramsConsumed(p) : 0;
}

/** Consumption-aware reorder suggestions modal (uses lib/reorder.js). */
/** Resolve a reorder unit price (per gram) + supplier for an item: prefer a
 *  matching supplier price-list entry (cheapest), else the item's own cost. */
function resolveReorderPrice(item) {
  if (typeof KhaytReorder !== 'undefined' && KhaytReorder.supplierPriceFor) {
    const sp = KhaytReorder.supplierPriceFor(suppliers, item.material);
    if (sp && sp.pricePerKg > 0) {
      return { perG: Math.round((sp.pricePerKg / 1000) * 1000) / 1000, supplierId: sp.supplierId, supplierName: sp.supplierName };
    }
  }
  // item.cost is the cost of the WHOLE SPOOL, not a per-gram rate — the stock
  // valuation at ~line 1572 divides it by spoolWeight, the CSV import maps
  // costPerKg onto it, and calculator-cost.js divides it by spoolWeight too.
  // Returning it undivided made every auto-drafted PO ~1000x too expensive,
  // because createPurchaseOrder multiplies unitPrice by a qty measured in GRAMS.
  // The supplier branch above already divides; only this fallback forgot.
  const perSpool = +item.cost || 0;
  const perG = perSpool > 0
    ? perSpool / Math.max(1, +item.spoolWeight || 1000)
    : (item.costPerKg ? +item.costPerKg / 1000 : 0);
  return { perG: perG > 0 ? Math.round(perG * 1000) / 1000 : 0, supplierId: item.supplierId || null, supplierName: '' };
}

/** Opt-in automation: silently draft purchase orders for low items that don't
 *  already have an open PO. Drafts only (owner reviews before ordering). Called
 *  on boot; no-op unless settings.autoDraftPo is on. Returns the count created. */
function maybeAutoDraftPurchaseOrders() {
  if (!settings.autoDraftPo || typeof KhaytReorder === 'undefined') return 0;
  const items = (typeof filterInventoryByLocation === 'function')
    ? filterInventoryByLocation(inventory, settings.activeLocationId) : inventory;
  const sug = KhaytReorder.reorderSuggestions(items, printLog, {
    now: Date.now(), windowDays: 30, partGrams: partGramsConsumed, isLow: isLowStock, leadDays: 14, targetDays: 45,
  });
  const need = KhaytReorder.itemsNeedingDraftPo(sug, purchaseOrders);
  if (!need.length) return 0;
  let n = 0;
  for (const s of need) {
    const kg = Math.max(0.25, Math.round((s.suggestG / 1000) * 4) / 4);
    const price = resolveReorderPrice(s.item);
    createPurchaseOrder(s.item, {
      qty: Math.round(kg * 1000), unitPrice: price.perG > 0 ? price.perG : undefined,
      supplierId: price.supplierId, supplierName: price.supplierName,
      status: 'draft', silent: true,
      notes: (t('reorder.auto_note') || 'Auto-drafted at reorder point') + ` · ~${Math.round(s.suggestG)} g`,
    });
    n++;
  }
  // Consumables, asked for by a user: running out of glue or bags stops a job the
  // way running out of filament does, and until now only filament reached this.
  // Their own module and their own dedupe — a consumable id and a spool id are
  // minted by the same uid(), so matching open POs across both would let one
  // silence the other. See lib/consumable-reorder.js.
  if (typeof KhaytConsumableReorder !== 'undefined' && Array.isArray(consumables)) {
    const CR = KhaytConsumableReorder;
    const csug = CR.consumableSuggestions(consumables, printLog, {
      now: Date.now(), windowDays: 30, leadDays: 14, targetDays: 45,
    });
    for (const s of CR.consumablesNeedingDraftPo(csug, purchaseOrders)) {
      createPurchaseOrder(s.item, {
        kind: 'consumable',
        qty: s.suggestQty,
        unitPrice: (+s.item.cost > 0) ? +s.item.cost : undefined,
        supplierId: s.item.supplierId || null,
        status: 'draft', silent: true,
        notes: (t('reorder.auto_note') || 'Auto-drafted at reorder point')
          + ` · ~${CR.qtyLabel(s.suggestQty, s.unit)}`,
      });
      n++;
    }
  }

  if (n > 0) {
    saveAll();
    if (typeof renderPurchaseOrders === 'function') renderPurchaseOrders();
    if (typeof renderReorderAlerts === 'function') renderReorderAlerts();
    toast((t('reorder.auto_drafted', { n }) || `Auto-drafted ${n} purchase order(s) — review in Inventory`), 'info', 6000);
  }
  return n;
}

function openReorderSuggestions() {
  if (typeof KhaytReorder === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const items = (typeof filterInventoryByLocation === 'function')
    ? filterInventoryByLocation(inventory, settings.activeLocationId) : inventory;
  const sug = KhaytReorder.reorderSuggestions(items, printLog, {
    now: Date.now(), windowDays: 30, partGrams: partGramsConsumed, isLow: isLowStock, leadDays: 14, targetDays: 45,
  });
  // Consumables run out too, and until now nothing but a vanishing toast said so.
  // Kept as a separate list rather than merged into the table above: every column
  // there is grams, and a count of boxes rendered under a "g" heading is the one
  // mistake that reaches a supplier's order form.
  const CR = (typeof KhaytConsumableReorder !== 'undefined') ? KhaytConsumableReorder : null;
  const csug = (CR && Array.isArray(consumables))
    ? CR.consumableSuggestions(consumables, printLog, { now: Date.now(), windowDays: 30, leadDays: 14, targetDays: 45 })
    : [];
  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
  const crows = csug.map((s) => {
    const days = s.daysLeft == null ? '—' : (s.daysLeft + 'd');
    const rate = s.perDay > 0 ? `${s.perDay}/${t('reorder.day') || 'day'}` : '—';
    const sugg = s.suggestQty > 0 ? CR.qtyLabel(s.suggestQty, s.unit) : (s.low ? (t('reorder.restock') || 'restock') : '—');
    const urgency = (s.daysLeft != null && s.daysLeft <= 7) ? 'var(--danger)' : (s.low ? 'var(--warning,#d97706)' : 'var(--text-muted)');
    return `<tr>
      <td style="padding:6px 8px;">${escapeHtml(s.label)}${s.low ? ` <span style="color:var(--warning,#d97706);">${_iIco('alert', '⚠', 12)}</span>` : ''}</td>
      <td style="padding:6px 8px;text-align:end;">${escapeHtml(CR.qtyLabel(s.stock, s.unit))}</td>
      <td style="padding:6px 8px;text-align:end;color:var(--text-muted);">${escapeHtml(rate)}</td>
      <td style="padding:6px 8px;text-align:end;color:${urgency};font-weight:600;">${escapeHtml(days)}</td>
      <td style="padding:6px 8px;text-align:end;">${escapeHtml(sugg)}</td>
    </tr>`;
  }).join('');
  const cDraftable = csug.filter((s) => s.suggestQty > 0);
  const rows = sug.map((s) => {
    const days = s.daysLeft == null ? '—' : (s.daysLeft + 'd');
    const rate = s.gramsPerDay > 0 ? `${s.gramsPerDay} g/${t('reorder.day') || 'day'}` : '—';
    const sugg = s.suggestG > 0 ? `${Math.round(s.suggestG)} g` : (s.low ? (t('reorder.restock') || 'restock') : '—');
    const urgency = (s.daysLeft != null && s.daysLeft <= 7) ? 'var(--danger)' : (s.low ? 'var(--warning,#d97706)' : 'var(--text-muted)');
    const committed = s.committedG > 0 ? `${Math.round(s.committedG)} g` : '—';
    return `<tr>
      <td style="padding:6px 8px;">${escapeHtml(s.label)}${s.low ? ` <span style="color:var(--warning,#d97706);">${_iIco('alert', '⚠', 12)}</span>` : ''}</td>
      <td style="padding:6px 8px;text-align:end;">${Math.round(s.weight)} g</td>
      <td style="padding:6px 8px;text-align:end;color:var(--text-muted);">${escapeHtml(committed)}</td>
      <td style="padding:6px 8px;text-align:end;color:var(--text-muted);">${escapeHtml(rate)}</td>
      <td style="padding:6px 8px;text-align:end;color:${urgency};font-weight:600;">${escapeHtml(days)}</td>
      <td style="padding:6px 8px;text-align:end;">${escapeHtml(sugg)}</td>
    </tr>`;
  }).join('');
  const draftable = sug.filter((s) => s.suggestG > 0);

  const listText = [
    KhaytReorder.reorderText(sug, { header: (t('reorder.title') || 'Reorder suggestions') + ':' }),
    CR ? CR.consumableReorderText(csug, {
      header: (t('reorder.consumables') || 'Consumables') + ':',
      restockLabel: t('reorder.restock') || 'restock',
    }) : '',
  ].filter(Boolean).join('\n\n');
  openFormModal({
    title: t('reorder.title') || 'Reorder suggestions',
    noSave: true,
    bodyHtml: (sug.length || csug.length) ? `
      ${sug.length ? `
      <p style="font-size:12px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(t('reorder.hint2') || 'Based on the last 30 days of usage and grams already committed to open orders. “Days left” projects available stock at that rate.')}</p>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead><tr style="text-align:start;color:var(--text-muted);border-bottom:1px solid var(--border,#eee);">
          <th style="padding:6px 8px;text-align:start;">${escapeHtml(t('reorder.material') || 'Material')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.in_stock') || 'In stock')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.committed') || 'Committed')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.rate') || 'Usage')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.days_left') || 'Days left')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.suggest') || 'Reorder')}</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table>` : ''}
      ${csug.length ? `
      <h4 style="margin:16px 0 6px;font-size:13px;">${escapeHtml(t('reorder.consumables') || 'Consumables')}</h4>
      <table style="width:100%;border-collapse:collapse;font-size:13px;">
        <thead><tr style="text-align:start;color:var(--text-muted);border-bottom:1px solid var(--border,#eee);">
          <th style="padding:6px 8px;text-align:start;">${escapeHtml(t('cons.name') || 'Item')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.in_stock') || 'In stock')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.rate') || 'Usage')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.days_left') || 'Days left')}</th>
          <th style="padding:6px 8px;text-align:end;">${escapeHtml(t('reorder.suggest') || 'Reorder')}</th>
        </tr></thead>
        <tbody>${crows}</tbody>
      </table>` : ''}
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px;">
        <button class="btn small" id="reorderCopy">${escapeHtml(t('reorder.copy_list') || 'Copy list')}</button>
        <button class="btn small" id="reorderWa">${escapeHtml(t('inv.share_whatsapp') || 'Share WhatsApp')}</button>
        ${(draftable.length + cDraftable.length) ? `<button class="btn small primary" id="reorderDraftPo">${escapeHtml(t('reorder.draft_po') || 'Draft purchase orders')} (${draftable.length + cDraftable.length})</button>` : ''}
      </div>`
      : `<p style="text-align:center;color:var(--text-muted);padding:20px 0;">${escapeHtml(t('reorder.none') || 'Stock looks healthy — nothing to reorder right now.')}</p>`,
    onMount(modal) {
      modal.querySelector('#reorderCopy')?.addEventListener('click', async () => {
        if (await copyText(listText)) toast(t('common.copied') || 'Copied!', 'success');
        else toast(listText, 'info', 8000);
      });
      modal.querySelector('#reorderWa')?.addEventListener('click', async () => {
        if (window.hubAPI?.shareWhatsApp) await window.hubAPI.shareWhatsApp({ phone: '', message: listText, pdfPath: null });
        else window.open(`https://wa.me/?text=${encodeURIComponent(listText)}`, '_blank');
      });
      modal.querySelector('#reorderDraftPo')?.addEventListener('click', async (e) => {
        const total = draftable.length + cDraftable.length;
        if (!(await confirmModal((t('reorder.draft_po_q', { n: total }) || `Create ${total} draft purchase order(s)?`)))) return;
        let n = 0;
        // Consumables first so a failure part-way still leaves the cheap, unit-
        // priced orders drafted rather than only the filament ones.
        for (const s of cDraftable) {
          createPurchaseOrder(s.item, {
            kind: 'consumable',
            qty: s.suggestQty,
            unitPrice: (+s.item.cost > 0) ? +s.item.cost : undefined,
            supplierId: s.item.supplierId || null,
            status: 'draft', silent: true,
            notes: (t('reorder.draft_note') || 'Auto-drafted from reorder forecast')
              + ` · ~${CR.qtyLabel(s.suggestQty, s.unit)}`,
          });
          n++;
        }
        for (const s of draftable) {
          const kg = Math.max(0.25, Math.round((s.suggestG / 1000) * 4) / 4); // round to 0.25kg
          // PO unitPrice is per-GRAM; prefer a supplier price-list match, else item cost.
          const price = resolveReorderPrice(s.item);
          createPurchaseOrder(s.item, {
            qty: Math.round(kg * 1000), unitPrice: price.perG > 0 ? price.perG : undefined,
            supplierId: price.supplierId, supplierName: price.supplierName,
            status: 'draft', silent: true,
            notes: (t('reorder.draft_note') || 'Auto-drafted from reorder forecast') + ` · ~${Math.round(s.suggestG)} g`,
          });
          n++;
        }
        saveAll();
        if (typeof renderPurchaseOrders === 'function') renderPurchaseOrders();
        toast((t('reorder.drafted', { n }) || `Created ${n} draft PO(s)`), 'success');
        if (e.target) { e.target.disabled = true; }
      });
    },
  });
}

function getSpoolReservedGrams(spoolId) {
  // Key on the same id the deduction uses: the explicitly chosen spool when set,
  // otherwise the part's filament (most parts only carry filamentId).
  return printLog
    .filter(o => o.status !== 'completed' && o.status !== 'quote' && !o.archived)
    .reduce((s, o) =>
      s + (o.parts || [])
        .reduce((ps, p) => ps + partGramsForSpool(p, spoolId), 0)
    , 0);
}

// Helper: return YYYY-MM-DD string n days from now
function todayPlusDays(n) {
  const d = new Date(); d.setHours(0,0,0,0); d.setDate(d.getDate() + n);
  return localDateStr(d);
}

// Feature 3: Check if saving parts would over-commit any spool
function checkSpoolOvercommit(parts, excludeOrderId) {
  const warnings = [];
  // Grams needed per spool across the parts being saved (colour-aware: a multicolour
  // part spreads its demand across each assigned colour filament).
  const needBySpool = {};
  for (const part of (parts || [])) {
    if (part.colours && part.colours.length) {
      const q = +part.qty || 1;
      for (const c of part.colours) {
        if (!c.filamentId) continue;
        needBySpool[c.filamentId] = (needBySpool[c.filamentId] || 0) + (+c.grams || 0) * q;
      }
    } else {
      const key = part.spoolId || part.filamentId;
      if (!key) continue;
      needBySpool[key] = (needBySpool[key] || 0) + partGramsConsumed(part);
    }
  }
  for (const [key, thisJobNeeds] of Object.entries(needBySpool)) {
    const item = inventory.find(i => i.id === key);
    if (!item) continue;
    // Compute already-reserved excluding the order being edited
    const alreadyReserved = printLog
      // !archived: renderPipelineDemand already excludes archived orders, so a
      // reservation that survives archiving contradicts the demand view beside it.
      .filter(o => o.status !== 'completed' && o.status !== 'quote' && !o.archived && o.id !== excludeOrderId)
      .reduce((s, o) =>
        s + (o.parts || []).reduce((ps, p) => ps + partGramsForSpool(p, key), 0)
      , 0);
    if (alreadyReserved + thisJobNeeds > item.weight) {
      warnings.push({
        spoolName: item.material,
        available: Math.max(0, item.weight - alreadyReserved),
        needed: thisJobNeeds,
      });
    }
  }
  return warnings;
}

/* ── Pipeline material demand ───────────────────────────── */
function renderPipelineDemand() {
  const el = $('#pipelineDemand');
  if (!el) return;

  const activeOrders = printLog.filter(o => o.status !== 'completed' && o.status !== 'quote' && !o.archived);
  if (activeOrders.length === 0) {
    el.innerHTML = '';
    return;
  }

  // Aggregate by material + colour
  const demand = {};
  for (const o of activeOrders) {
    for (const p of (o.parts || [])) {
      const mat = p.material || p.filament || '';
      const col = p.colour || p.color || '';
      const key = mat ? (col ? `${mat} / ${col}` : mat) : (col || t('inv.unknown_material') || 'Unknown');
      const grams = +(p.printWeight || p.weight || 0);
      if (!demand[key]) demand[key] = { grams: 0, count: 0, mat, col };
      demand[key].grams += grams;
      demand[key].count++;
    }
  }

  const entries = Object.entries(demand)
    .filter(([, d]) => d.grams > 0)
    .sort((a, b) => b[1].grams - a[1].grams);

  if (entries.length === 0) {
    el.innerHTML = '';
    return;
  }

  const rows = entries.map(([key, d]) => {
    // Check if we have enough stock
    const totalStock = inventory
      .filter(spool => {
        const spoolMat = spool.material || spool.filament || '';
        const spoolCol = spool.colour || spool.color || '';
        return spoolMat.toLowerCase() === d.mat.toLowerCase() &&
               (!d.col || spoolCol.toLowerCase() === d.col.toLowerCase());
      })
      .reduce((s, spool) => s + (+spool.remaining || +spool.weight || 0), 0);
    const deficit = totalStock - d.grams;
    const color = deficit >= 0 ? 'var(--success)' : 'var(--danger)';
    const icon  = deficit >= 0 ? _iIco('check', '✅') : _iIco('alert', '⚠');
    return `<div style="display:flex;align-items:center;gap:10px;padding:5px 0;border-bottom:1px solid var(--border);">
      <span style="font-size:13px;color:${color};">${icon}</span>
      <div style="flex:1;min-width:0;">
        <span style="font-size:12.5px;font-weight:500;">${escapeHtml(key)}</span>
      </div>
      <div style="font-size:12px;text-align:end;white-space:nowrap;">
        <span style="color:var(--text);">${d.grams.toFixed(0)}g ${escapeHtml(t('inv.needed') || 'needed')}</span>
        <span style="color:${color};margin-inline-start:8px;font-size:11px;">${deficit >= 0 ? `${totalStock.toFixed(0)}g ${escapeHtml(t('inv.in_stock') || 'in stock')}` : `${Math.abs(deficit).toFixed(0)}g ${escapeHtml(t('inv.short') || 'short')}`}</span>
      </div>
    </div>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="margin-bottom:16px;border-inline-start:3px solid var(--primary);">
      <h3 class="card-head" style="margin-bottom:8px;"><span class="swatch" style="background:var(--primary);"></span>
        ${escapeHtml(t('inv.pipeline_title'))}
        <span class="count" style="margin-inline-start:6px;">${activeOrders.length}</span>
      </h3>
      ${rows}
    </div>`;
}

// Feature F2: Render a prominent amber alert banner listing all low-stock items
function renderReorderAlerts() {
  const el = $('#reorderAlertsSection');
  if (!el) return;

  const activeLoc = (typeof activeLocation !== 'undefined') ? activeLocation : null;
  const scopedInv = filterInventoryByLocation(inventory, activeLoc);
  const lowItems = scopedInv.filter(isLowStock);

  if (lowItems.length === 0) {
    el.innerHTML = '';
    el.style.display = 'none';
    return;
  }

  const collapsed = el.dataset.collapsed === 'true';

  const itemRows = lowItems.map(item => {
    const daysLeft = estimateDaysRemaining(item);
    const daysHtml = daysLeft !== null
      ? `<span style="font-size:11px;color:${daysLeft <= 3 ? 'var(--danger)' : 'var(--warning)'};margin-inline-start:6px;" title="${escapeHtml(t('inv.usage_prediction') || 'Usage prediction')}">${_iIcoL('clock', '⏱', 12)}${escapeHtml(t('inv.est_days_remaining') || 'Est.')} ${daysLeft}d</span>`
      : '';
    const threshold = item.reorderPoint ?? settings.lowStockThreshold ?? 200;
    return `<div style="display:flex;align-items:center;gap:8px;padding:5px 10px;background:rgba(245,166,35,0.08);border-radius:var(--radius-sm);margin-bottom:4px;flex-wrap:wrap;">
      <span style="width:10px;height:10px;border-radius:50%;background:${safeCssColor(item.color, '#f5a623')};display:inline-block;flex-shrink:0;"></span>
      <span style="flex:1;font-size:12.5px;font-weight:600;">${escapeHtml(item.material)}${item.colourVariant ? ` — ${escapeHtml(item.colourVariant)}` : ''}</span>
      <span style="font-size:11.5px;color:var(--danger);white-space:nowrap;">${Math.round(item.weight)}g / ${Math.round(threshold)}g</span>
      ${daysHtml}
      <button class="btn small primary" data-act="reorder-alert-item" data-id="${escapeHtml(item.id)}" style="font-size:11px;padding:2px 8px;">${escapeHtml(t('inv.draft_po') || 'Draft PO')}</button>
    </div>`;
  }).join('');

  el.style.display = '';
  el.innerHTML = `
    <div style="border:1px solid rgba(245,166,35,0.4);border-radius:var(--radius);background:rgba(245,166,35,0.06);margin-bottom:14px;overflow:hidden;">
      <div style="display:flex;align-items:center;gap:10px;padding:10px 14px;cursor:pointer;background:rgba(245,166,35,0.1);" id="reorderAlertToggle"
        role="button" tabindex="0" aria-expanded="${collapsed ? 'false' : 'true'}" aria-label="${escapeHtml(t('inv.low_stock_alerts') || 'Low stock alerts')}">
        <span style="font-size:16px;color:var(--warning);">${_iIco('alert', '⚠', 17)}</span>
        <span style="font-weight:700;color:var(--low-stock);flex:1;">${escapeHtml(t('inv.low_stock_alert') || 'Low Stock Alert')} <span style="background:var(--low-stock);color:#000;font-size:11px;padding:1px 6px;border-radius:10px;margin-inline-start:4px;">${lowItems.length}</span></span>
        <span style="font-size:12px;color:var(--text-muted);">${collapsed ? '▶' : '▼'}</span>
      </div>
      ${collapsed ? '' : `<div style="padding:10px 14px;">${itemRows}</div>`}
    </div>`;

  const toggle = el.querySelector('#reorderAlertToggle');
  if (toggle) {
    toggle.addEventListener('click', () => {
      el.dataset.collapsed = collapsed ? 'false' : 'true';
      renderReorderAlerts();
    });
  }
  el.querySelectorAll('[data-act="reorder-alert-item"]').forEach(btn => {
    btn.addEventListener('click', () => openReorderModal(btn.dataset.id));
  });
}

/** Inventory-tab scope banner: mirrors the queue/dashboard location banner. */
function renderInventoryLocationScopeBanner(activeLoc, shownCount, totalCount) {
  const host = document.getElementById('invLocationScopeBanner');
  if (!host) return;
  const loc = activeLoc && typeof locations !== 'undefined'
    ? locations.find(l => l.id === activeLoc) : null;
  if (!loc) {
    host.innerHTML = '';
    host.style.display = 'none';
    return;
  }
  const hidden = Math.max(0, (totalCount || 0) - (shownCount || 0));
  host.style.display = 'flex';
  host.innerHTML = `
    <span style="font-size:12px;color:var(--text-muted);">
      ${escapeHtml(t('inv.scoped_to') || t('loc.filtering') || 'Showing stock at')}
      <strong style="color:var(--text);">${escapeHtml(loc.name)}</strong>
      ${hidden > 0 ? `<span style="margin-inline-start:6px;color:var(--text-dim);">(${hidden} ${escapeHtml(t('inv.scoped_hidden') || 'hidden at other sites')})</span>` : ''}
    </span>
    <button type="button" class="btn small ghost" data-act="clear-location-filter">${escapeHtml(t('loc.show_all') || 'Show all')}</button>`;
}

function renderInventory() {
  window.KhaytBedReadyUI?.renderInventoryStudioStats?.();
  renderReorderAlerts();
  renderSupplierReorderList();
  renderPipelineDemand();
  // Per-location scope (#65 follow-up): valuation, banner, list all scope to
  // the active branch (+ unassigned legacy stock). Null = all sites.
  const activeLoc = (typeof activeLocation !== 'undefined') ? activeLocation : null;
  const scopedInventory = filterInventoryByLocation(inventory, activeLoc);
  renderInventoryLocationScopeBanner(activeLoc, scopedInventory.length, inventory.length);
  // Inventory valuation summary
  const valEl = $('#invValuationSummary');
  if (valEl && !window.KhaytBedReadyUI?.useHandoffScreens?.()) {
    if (scopedInventory.length > 0) {
      const totalValue = scopedInventory.reduce((s, item) => {
        // Value = cost × (remaining / original). Fall back to the standard spool
        // size (1000) when the original weight wasn't recorded — dividing by the
        // *remaining* weight valued every partly-used spool at full purchase cost.
        const pricePerG = item.weight > 0 && item.cost > 0 ? item.cost / Math.max(1, item.spoolWeight || 1000) * item.weight : 0;
        return s + pricePerG;
      }, 0);
      const totalGrams = scopedInventory.reduce((s, item) => s + Math.max(0, +item.weight || 0), 0);
      const lowCount = scopedInventory.filter(isLowStock).length;
      valEl.innerHTML = `
        <span>${escapeHtml(t('inv.total_value'))}: <strong style="color:var(--success);">${fmtMoney(totalValue)}</strong></span>
        <span style="margin-inline-start:16px;">${escapeHtml(t('inv.total_stock'))}: <strong>${fmtCount(Math.round(totalGrams))}g</strong></span>
        ${lowCount > 0 ? `<span style="margin-inline-start:16px; color:var(--low-stock);">${_iIcoL('alert', '⚠')}${lowCount} ${escapeHtml(t('inv.low_stock_count'))}</span>` : ''}
      `;
      valEl.style.display = 'flex';
    } else {
      valEl.style.display = 'none';
    }
  }

  window.KhaytBedReadyUI?.patchInventoryTableHead?.();
  const _studioInv = window.KhaytBedReadyUI?.useHandoffScreens?.();
  const tbody = $('#inventoryTable tbody');
  if (inventory.length === 0) {
    tbody.innerHTML = `<tr><td colspan="${_studioInv ? 6 : 5}" class="empty-state">${escapeHtml(t('inv.empty'))} <button type="button" class="btn small primary" data-act="focus-inv-material" style="margin-inline-start:12px;">${escapeHtml(t('inv.add_title') || 'Add Filament')}</button></td></tr>`;
  } else if (scopedInventory.length === 0) {
    // Stock exists but none at the active branch (and no unassigned spools).
    tbody.innerHTML = `<tr><td colspan="${_studioInv ? 6 : 5}" class="empty-state">${escapeHtml(t('inv.empty_location') || 'No stock at this location.')}</td></tr>`;
  } else {
    const todayMs = Date.now();
    const invTerm = invSearchTerm.toLowerCase().trim();
    const visibleInv = invTerm
      ? scopedInventory.filter(i => (i.material || '').toLowerCase().includes(invTerm) || (i.colourVariant || '').toLowerCase().includes(invTerm))
      : scopedInventory;
    // Build a forecast map: materialName → daysRemaining
    const forecastMap = {};
    try {
      computeMaterialForecast().forEach(f => { forecastMap[f.material] = f; });
    } catch(e) { /* silent */ }
    tbody.innerHTML = visibleInv.map(item => {
      const studioRow = window.KhaytBedReadyUI?.renderInventoryRow?.(item, { forecastMap, todayMs });
      if (studioRow) return studioRow;
      const low = isLowStock(item);
      const queued = Math.round(getQueuedWeight(item.id));
      const warn   = queued > 0 && queued > item.weight;
      // Spool age badge
      const refDate = item.openedAt || item.purchasedAt;
      let ageBadge = '';
      if (refDate) {
        const ageMonths = Math.floor((todayMs - new Date(refDate + 'T00:00:00').getTime()) / (30.44 * 86400000));
        if (ageMonths >= 12) {
          ageBadge = ` <span style="font-size:10px; color:var(--danger); font-weight:600;" title="${escapeHtml(t('inv.spool_old_tip'))}">${_iIcoL('alert', '⚠', 12)}${ageMonths}mo</span>`;
        } else if (ageMonths >= 6) {
          ageBadge = ` <span style="font-size:10px; color:var(--warning);" title="${escapeHtml(t('inv.spool_age_tip'))}">${_iIcoL('clock', '📅', 12)}${ageMonths}mo</span>`;
        }
      }
      const reserved = Math.round(getSpoolReservedGrams(item.id));
      const isOvercommit = reserved > item.weight;
      const reservedBadge = reserved > 0
        ? ` <span class="spool-reserved-badge">${escapeHtml(t('inv.reserved'))}: ${reserved}${escapeHtml(t('common.grams'))}</span>`
        : '';
      const overcommitBadge = isOvercommit
        ? ` <span style="background:var(--danger);color:#fff;font-size:10px;padding:1px 5px;border-radius:3px;font-weight:600;">${_iIcoL('alert', '⚠', 12)}${escapeHtml(t('inv.overcommit_warn'))}</span>`
        : '';
      // Feature 7: Test prints badge
      const spoolTestCount = testPrints.filter(tp => tp.spoolId === item.id).length;
      const testBadge = spoolTestCount > 0
        ? ` <span style="font-size:10px;color:var(--primary);">${_iIcoL('flask', '🧪', 12)}${spoolTestCount}</span>`
        : '';
      // Run-out forecast badge
      const fc = forecastMap[item.material];
      const runoutBadge = fc
        ? fc.available < 0
          ? ` <span style="font-size:10px;background:var(--danger);color:#fff;padding:1px 5px;border-radius:3px;font-weight:600;">${_iIcoL('alert', '⚠', 12)}${escapeHtml(t('inv.overcommit_warn'))}</span>`
          : ` <span style="font-size:10px;color:${fc.urgent ? 'var(--danger)' : 'var(--warning)'};font-weight:600;" title="${escapeHtml(t('inv.runout_in') || 'Run-out in')} ${fc.daysRemaining} ${escapeHtml(t('common.days') || 'days')}">${_iIcoL('trend', '📉', 12)}${fc.daysRemaining}d</span>`
        : '';
      const isResin = item.materialType === 'resin';
      const weightUnit = isResin ? 'mL' : escapeHtml(t('common.grams'));
      const resinBadge = isResin ? ` <span class="resin-badge">${escapeHtml(t('inv.type_resin'))}</span>` : '';
      const colourChip = item.colourVariant ? ` <span class="variant-chip">${escapeHtml(item.colourVariant)}</span>` : '';
      const lotChip = item.lot ? ` <span style="font-size:10px; color:var(--text-dim); background:var(--bg-elev); border:1px solid var(--border-soft); border-radius:3px; padding:0 4px;" title="${escapeHtml(t('inv.lot') || 'Lot')}">${escapeHtml(item.lot)}</span>` : '';
      // Per-location: show which branch a spool belongs to (legacy/unassigned hidden).
      const locChip = (item.locationId && typeof locationBadgeHtml === 'function')
        ? ` ${locationBadgeHtml(item.locationId)}`
        : '';
      return `
        <tr data-inv-id="${escapeHtml(item.id)}"${low ? ' style="background: rgba(245,166,35,0.08);"' : ''}>
          <td style="display:flex; align-items:center; gap:8px; flex-wrap:wrap;">
            <span style="display:inline-block; width:12px; height:12px; border-radius:50%; background:${safeCssColor(item.color, '#888888')}; flex-shrink:0; border:1px solid rgba(255,255,255,0.15);"></span>
            <strong>${escapeHtml(item.material)}</strong>${low ? ' <span style="color:var(--low-stock); font-size:11px;">· low</span>' : ''}${resinBadge}${colourChip}${lotChip}${locChip}${ageBadge}${reservedBadge}${overcommitBadge}${testBadge}${runoutBadge}
            ${item.printTemp || item.bedTemp ? `<span style="font-size:10px; color:var(--primary);">${_iIcoL('thermo', '🌡', 12)}${item.printTemp ? item.printTemp + '°C print' : ''}${item.printTemp && item.bedTemp ? ' / ' : ''}${item.bedTemp ? item.bedTemp + '°C bed' : ''}</span>` : ''}
          </td>
          <td style="font-variant-numeric: tabular-nums;">${fmtPrice(item.cost)}</td>
          <td style="font-variant-numeric: tabular-nums;">
            ${window.KhaytBedReadyUI?.useHandoffScreens?.() ? window.KhaytBedReadyUI.invStockMeterHtml(item) : `${Math.round(item.weight)} ${weightUnit}`}
          </td>
          <td style="font-variant-numeric: tabular-nums; color:${queued > 0 ? (warn ? 'var(--danger)' : 'var(--text-dim)') : 'var(--text-muted)'};">
            ${queued > 0 ? Math.round(queued) + ' ' + weightUnit : '—'}${warn ? ` <span style="color:var(--danger); font-size:11px;">${_iIco('alert', '⚠', 12)}</span>` : ''}
          </td>
          <td style="white-space:nowrap;">
            ${(() => {
              const mat = (item.material || '').toLowerCase();
              const isHygroscopic = ['nylon','pa','tpu','tpe','pva','petg'].some(h => mat.includes(h));
              if (!isHygroscopic) return '';
              const dryLog = item.dryingLog || [];
              if (dryLog.length === 0) {
                return `<span class="drying-warn-badge" style="margin-inline-end:6px;" title="${escapeHtml(t('inv.dry_log'))}">${_iIcoL('alert', '⚠', 12)}${escapeHtml(t('inv.dry_warn'))}</span>`;
              }
              const lastDry = [...dryLog].sort((a, b) => (b.date || '').localeCompare(a.date || ''))[0];
              const daysSince = lastDry.date ? Math.floor((Date.now() - new Date(lastDry.date + 'T00:00:00').getTime()) / 86400000) : 999;
              if (daysSince > 7) {
                return `<span class="drying-warn-badge" style="margin-inline-end:6px;">${_iIcoL('alert', '⚠', 12)}${escapeHtml(t('inv.dry_warn'))}</span>`;
              }
              return `<span class="drying-ok-badge" style="margin-inline-end:6px;">${_iIcoL('check', '✅', 12)}${escapeHtml(t('inv.dry_ok', { n: daysSince }))}</span>`;
            })()}
            ${low ? `<button class="btn small" data-act="reorder-inv" data-id="${item.id}" style="margin-inline-end:4px; color:var(--low-stock); border-color:var(--low-stock);">${escapeHtml(t('inv.reorder'))}</button>` : ''}
            <button class="btn small ghost" data-act="inv-test-print" data-id="${item.id}" style="margin-inline-end:4px;" title="${escapeHtml(t('inv.test_prints'))}">${_iIco('flask', '🧪')}</button>
            <button class="btn small ghost" data-act="inv-dry-log" data-id="${item.id}" style="margin-inline-end:4px;" title="${escapeHtml(t('inv.dry_log'))}">${_iIco('thermo', '🌡')}</button>
            <button class="btn small ghost" data-act="inv-spool-history" data-id="${item.id}" style="margin-inline-end:4px;" title="${escapeHtml(t('inv.spool_history'))}">${_iIco('clipboard', '📋')}</button>
            <button class="btn small ghost" data-act="inv-print-label" data-id="${item.id}" style="margin-inline-end:4px;" title="${escapeHtml(t('inv.print_label') || 'Print label')}">${_iIco('tag', '🏷')}</button>
            ${(typeof locations !== 'undefined' && locations.length > 0) ? `<button class="btn small ghost" data-act="inv-transfer" data-id="${item.id}" style="margin-inline-end:4px;" title="${escapeHtml(t('inv.transfer') || 'Transfer')}" aria-label="${escapeHtml(t('inv.transfer') || 'Transfer')}"><span aria-hidden="true">↔</span></button>` : ''}
            <button class="btn small ghost" data-act="adj-inv" data-id="${item.id}" style="margin-inline-end:4px;">${escapeHtml(t('inv.adjust'))}</button>
            ${(item.priceHistory && item.priceHistory.length > 0) ? `<button class="btn small ghost" data-act="inv-price-history" data-id="${item.id}" style="margin-inline-end:4px;" title="${escapeHtml(t('inv.price_history'))}">${_iIco('trend', '📈')}</button>` : ''}
            <button class="btn small" data-act="edit-inv" data-id="${item.id}" style="margin-inline-end:4px;">${escapeHtml(t('common.edit'))}</button>
            <button class="btn danger small" data-act="del-inv" data-id="${item.id}">${escapeHtml(t('common.delete'))}</button>
          </td>
        </tr>`;
    }).join('');
  }
  populateFilamentDropdown();
  populateInvLocationField();
  updateNotifBadge();
}

/** Show/populate the add-spool location picker only when branches are defined. */
function populateInvLocationField() {
  const wrap = document.getElementById('invLocationField');
  const sel = document.getElementById('invLocation');
  if (!wrap || !sel) return;
  const locs = (typeof locations !== 'undefined') ? locations : [];
  if (!locs.length) { wrap.style.display = 'none'; return; }
  const activeLoc = (typeof activeLocation !== 'undefined') ? activeLocation : null;
  const prev = sel.value;
  sel.innerHTML = `<option value="">${escapeHtml(t('inv.location_unassigned') || 'Unassigned')}</option>` +
    locs.map(l => `<option value="${escapeHtml(l.id)}">${escapeHtml(l.name)}</option>`).join('');
  sel.value = (prev && locs.some(l => l.id === prev)) ? prev : (activeLoc || '');
  wrap.style.display = '';
}

function openStockAdjustModal(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const today = localDateStr();
  if (!item.adjustments) item.adjustments = [];
  const recentAdjs = item.adjustments.slice(0, 5);

  const histHtml = recentAdjs.length === 0
    ? ''
    : `<div style="margin-top:16px; padding-top:12px; border-top:1px solid var(--border-soft);">
        <label style="margin-top:0; font-size:12px; font-weight:600; color:var(--text-muted);">${escapeHtml(t('inv.adj_history'))}</label>
        <div style="margin-top:6px;">
          ${recentAdjs.map(adj => `
            <div style="display:flex; justify-content:space-between; font-size:12px; color:var(--text-dim); padding:3px 0; border-bottom:1px solid rgba(255,255,255,0.04);">
              <span>${escapeHtml(adj.date)}</span>
              <span style="color:${adj.type === 'add' ? 'var(--success)' : 'var(--danger)'};">${adj.type === 'add' ? '+' : '-'}${escapeHtml(String(adj.amount))}g</span>
              <span style="flex:1; text-align:right; color:var(--text-muted);">${escapeHtml(adj.reason || '')}</span>
            </div>`).join('')}
        </div>
      </div>`;

  openFormModal({
    title: `${t('inv.adjust_title')} — ${escapeHtml(item.material)}`,
    saveLabel: t('common.save'),
    bodyHtml: `
      <p style="font-size:13px; color:var(--text-muted); margin:0 0 12px;">
        ${escapeHtml(t('inv.current_stock'))}: <strong>${Math.round(item.weight)}g</strong>
      </p>
      <label>${escapeHtml(t('inv.adj_amount'))} </label>
      <input type="number" id="adjAmountInput" min="1" step="1" value="" placeholder="0">
      <label style="margin-top:12px;">${escapeHtml(t('inv.adj_reason'))}</label>
      <input type="text" id="adjReasonInput" placeholder="">
      <div style="margin-top:12px; display:flex; gap:16px;">
        <label style="display:flex; align-items:center; gap:6px; cursor:pointer;">
          <input type="radio" name="adjType" value="add" checked style="width:auto; margin:0;">
          <span style="color:var(--success);">+ ${escapeHtml(t('inv.adj_add'))}</span>
        </label>
        <label style="display:flex; align-items:center; gap:6px; cursor:pointer;">
          <input type="radio" name="adjType" value="remove" style="width:auto; margin:0;">
          <span style="color:var(--danger);">− ${escapeHtml(t('inv.adj_remove'))}</span>
        </label>
      </div>
      ${histHtml}`,
    onSave() {
      const amount = num(document.getElementById('adjAmountInput').value, 0);
      if (amount <= 0) { toast(t('sup.amount_required'), 'error'); return false; }
      const type   = document.querySelector('input[name="adjType"]:checked').value;
      const reason = document.getElementById('adjReasonInput').value.trim();
      if (!item.adjustments) item.adjustments = [];
      item.adjustments.unshift({ id: uid('ADJ'), date: today, type, amount, reason });
      if (type === 'add') {
        item.weight = Math.max(0, item.weight + amount);
      } else {
        item.weight = Math.max(0, item.weight - amount);
      }
      saveAll();
      renderInventory();
      toast(t('inv.adj_saved'), 'success');
      return true;
    }
  });
}

/* ============================================================
   Spool usage history (Feature 3)
   ============================================================ */
function openSpoolHistory(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const history = item.usageHistory || [];
  const totalConsumed = history.reduce((s, h) => s + (+h.weightUsed || 0), 0);
  const tableHtml = history.length === 0
    ? `<p style="color:var(--text-muted); font-size:13px; text-align:center; padding:16px 0;">${escapeHtml(t('inv.spool_hist_empty'))}</p>`
    : `<div class="table-wrap"><table style="width:100%;">
        <thead><tr>
          <th>${escapeHtml(t('common.date'))}</th>
          <th>${escapeHtml(t('log.client'))}</th>
          <th>${escapeHtml(t('inv.spool_hist_weight'))}</th>
        </tr></thead>
        <tbody>${history.map(h => {
          const orderLabel = h.orderId
            ? `<a class="spool-hist-order-link" href="#" data-order-id="${escapeHtml(h.orderId)}" style="color:var(--primary); text-decoration:none; font-size:12px;">${escapeHtml(h.project || h.orderId)}</a>`
            : escapeHtml(h.project || '');
          return `<tr>
            <td style="font-family:var(--font-num); font-size:12px; color:var(--text-dim); white-space:nowrap;">${escapeHtml(h.date || '')}</td>
            <td>${orderLabel}</td>
            <td style="text-align:right; font-variant-numeric:tabular-nums;">${(+h.weightUsed || 0).toFixed(0)}g</td>
          </tr>`;
        }).join('')}</tbody>
      </table></div>`;
  openFormModal({
    title: `${t('inv.spool_history')} — ${escapeHtml(item.material)}`,
    noSave: true,
    sizeLg: true,
    bodyHtml: `
      <div style="display:flex; gap:20px; flex-wrap:wrap; margin-bottom:14px; font-size:13px;">
        <span>${escapeHtml(t('inv.current_stock'))}: <strong>${Math.round(item.weight)}g</strong></span>
        <span>${escapeHtml(t('inv.spool_consumed'))}: <strong>${totalConsumed.toFixed(0)}g</strong></span>
      </div>
      ${tableHtml}`,
    onMount(modal) {
      modal.querySelectorAll('.spool-hist-order-link').forEach(link => {
        link.addEventListener('click', (e) => {
          e.preventDefault();
          const oid = link.dataset.orderId;
          // Close modal by clicking cancel, then navigate
          modal.closest('.modal-backdrop')?.querySelector('[data-act="cancel"]')?.click();
          switchTab('logs-tab');
          setTimeout(() => { logSearchTerm = oid; renderLogs(); }, 60);
        });
      });
    },
  });
}

/* ============================================================
   Filament drying log (Feature 4)
   ============================================================ */
function openDryingLog(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  if (!item.dryingLog) item.dryingLog = [];
  const todayStr = localDateStr();

  function listHtml() {
    const log = [...item.dryingLog].sort((a, b) => (b.date || '').localeCompare(a.date || ''));
    if (log.length === 0)
      return `<p style="color:var(--text-muted); font-size:13px; text-align:center; padding:10px 0;">${escapeHtml(t('inv.dry_log'))} — ${escapeHtml(t('inv.spool_hist_empty'))}</p>`;
    return `<div class="table-wrap"><table style="width:100%;">
      <thead><tr>
        <th>${escapeHtml(t('inv.dry_date'))}</th>
        <th>${escapeHtml(t('inv.dry_temp'))}</th>
        <th>${escapeHtml(t('inv.dry_duration'))}</th>
        <th>${escapeHtml(t('common.notes'))}</th>
        <th></th>
      </tr></thead>
      <tbody>${log.map(e => `<tr>
        <td style="white-space:nowrap; font-size:12px; color:var(--text-dim);">${escapeHtml(e.date || '')}</td>
        <td style="text-align:center;">${e.tempC ? escapeHtml(String(e.tempC)) + '°C' : '—'}</td>
        <td style="text-align:center;">${e.durationH ? escapeHtml(String(e.durationH)) + 'h' : '—'}</td>
        <td style="color:var(--text-muted); font-size:12.5px;">${escapeHtml(e.notes || '')}</td>
        <td><button class="btn danger small" data-act="del-dry" data-dry-id="${e.id}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button></td>
      </tr>`).join('')}
      </tbody>
    </table></div>`;
  }

  openFormModal({
    title: `${escapeHtml(item.material)} — ${t('inv.dry_log')}`,
    saveLabel: t('inv.dry_add'),
    sizeLg: true,
    bodyHtml: `
      <div style="background:var(--surface-2); padding:14px; border-radius:var(--radius); margin-bottom:14px;">
        <div style="display:grid; grid-template-columns:1fr 1fr 1fr 2fr; gap:8px; align-items:end;">
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.dry_date'))}</label>
            <input type="date" id="dryDate" value="${todayStr}">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.dry_temp'))}</label>
            <input type="number" id="dryTemp" min="0" max="120" step="1" placeholder="65">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.dry_duration'))}</label>
            <input type="number" id="dryDuration" min="0" step="0.5" placeholder="4">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('common.notes'))}</label>
            <input type="text" id="dryNotes" placeholder="${escapeHtml(t('common.optional'))}">
          </div>
        </div>
      </div>
      <div id="dryLogList">${listHtml()}</div>
    `,
    onMount(modal) {
      modal.querySelector('#dryLogList').addEventListener('click', async (e) => {
        const btn = e.target.closest('[data-act="del-dry"]');
        if (!btn) return;
        const ok = await confirmModal(t('common.delete') + '?', { danger: true });
        if (!ok) return;
        item.dryingLog = item.dryingLog.filter(e2 => e2.id !== btn.dataset.dryId);
        saveAll();
        modal.querySelector('#dryLogList').innerHTML = listHtml();
      });
    },
    onSave(modal) {
      const date     = modal.querySelector('#dryDate').value     || todayStr;
      const tempC    = parseFloat(modal.querySelector('#dryTemp').value)     || null;
      const durationH = parseFloat(modal.querySelector('#dryDuration').value) || null;
      const notes    = modal.querySelector('#dryNotes').value.trim();
      item.dryingLog.unshift({ id: uid('DRY'), date, tempC, durationH, notes });
      saveAll();
      renderInventory();
      toast(t('inv.dry_add'), 'success');
      return true;
    }
  });
}

/* ============================================================
   Feature 7: Test Print / Calibration Library
   ============================================================ */
function openTestPrintLog(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const todayStr = localDateStr();
  const TEST_TYPES = ['temp_tower','retraction','first_layer','stringing','overhang','dimensional','other'];
  const TEST_RESULTS = ['excellent','good','fair','poor'];

  function listHtml() {
    const entries = testPrints.filter(tp => tp.spoolId === itemId)
      .sort((a, b) => (b.date || '').localeCompare(a.date || ''));
    if (entries.length === 0)
      return `<p style="color:var(--text-muted); font-size:13px; text-align:center; padding:10px 0;">${escapeHtml(t('inv.spool_hist_empty'))}</p>`;
    return `<div class="table-wrap"><table style="width:100%; font-size:12px;">
      <thead><tr>
        <th>${escapeHtml(t('common.date'))}</th>
        <th>${escapeHtml(t('inv.test_machine'))}</th>
        <th>${escapeHtml(t('inv.test_type'))}</th>
        <th>Print°C</th>
        <th>Bed°C</th>
        <th>${escapeHtml(t('inv.test_speed'))}</th>
        <th>${escapeHtml(t('inv.test_result'))}</th>
        <th>${escapeHtml(t('common.notes'))}</th>
        <th>${escapeHtml(t('inv.test_weight_used'))}</th>
        <th></th>
      </tr></thead>
      <tbody>${entries.map(e => {
        const mach = e.machineId ? machines.find(m => m.id === e.machineId) : null;
        return `<tr>
          <td style="white-space:nowrap; color:var(--text-dim);">${escapeHtml(e.date || '')}</td>
          <td>${mach ? escapeHtml(mach.name) : '—'}</td>
          <td>${escapeHtml(t('inv.test.' + (e.testType || 'other')))}</td>
          <td>${e.printTemp ? escapeHtml(String(e.printTemp)) + '°' : '—'}</td>
          <td>${e.bedTemp ? escapeHtml(String(e.bedTemp)) + '°' : '—'}</td>
          <td>${e.speed ? escapeHtml(String(e.speed)) : '—'}</td>
          <td style="color:${e.result === 'excellent' || e.result === 'good' ? 'var(--success)' : e.result === 'poor' ? 'var(--danger)' : 'var(--warning)'};">${escapeHtml(t('inv.test.' + (e.result || 'good')))}</td>
          <td style="color:var(--text-muted);">${escapeHtml(e.notes || '')}</td>
          <td>${e.weightUsed ? escapeHtml(String(e.weightUsed)) + 'g' : '—'}</td>
          <td><button class="btn danger small" data-act="del-test" data-test-id="${e.id}" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button></td>
        </tr>`;
      }).join('')}
      </tbody>
    </table></div>`;
  }

  const machOptions = `<option value="">${escapeHtml(t('mach.unassigned'))}</option>` +
    machines.map(m => `<option value="${m.id}">${escapeHtml(m.name)}</option>`).join('');
  const typeOptions = TEST_TYPES.map(tp => `<option value="${tp}">${escapeHtml(t('inv.test.' + tp))}</option>`).join('');
  const resultOptions = TEST_RESULTS.map(r => `<option value="${r}">${escapeHtml(t('inv.test.' + r))}</option>`).join('');

  openFormModal({
    title: `${escapeHtml(item.material)} — ${t('inv.test_prints')}`,
    saveLabel: t('inv.test_add'),
    sizeLg: true,
    bodyHtml: `
      <div style="background:var(--surface-2); padding:14px; border-radius:var(--radius); margin-bottom:14px;">
        <div style="display:grid; grid-template-columns:repeat(4, 1fr); gap:8px; align-items:end;">
          <div>
            <label style="margin:0;">${escapeHtml(t('common.date'))}</label>
            <input type="date" id="tpDate" value="${todayStr}" max="${todayStr}">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.test_machine'))}</label>
            <select id="tpMachine">${machOptions}</select>
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.test_type'))}</label>
            <select id="tpType">${typeOptions}</select>
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.test_result'))}</label>
            <select id="tpResult">${resultOptions}</select>
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.print_temp'))}</label>
            <input type="number" id="tpPrintTemp" min="0" max="350" step="1" placeholder="210">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.bed_temp'))}</label>
            <input type="number" id="tpBedTemp" min="0" max="150" step="1" placeholder="60">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.test_speed'))}</label>
            <input type="number" id="tpSpeed" min="0" step="1" placeholder="60">
          </div>
          <div>
            <label style="margin:0;">${escapeHtml(t('inv.test_weight_used'))}</label>
            <input type="number" id="tpWeight" min="0" step="1" placeholder="5">
          </div>
        </div>
        <div style="margin-top:8px;">
          <label style="margin:0;">${escapeHtml(t('common.notes'))}</label>
          <input type="text" id="tpNotes" placeholder="${escapeHtml(t('common.optional'))}">
        </div>
      </div>
      <div id="testPrintList">${listHtml()}</div>
    `,
    onMount(modal) {
      modal.querySelector('#testPrintList').addEventListener('click', async (e) => {
        const btn = e.target.closest('[data-act="del-test"]');
        if (!btn) return;
        const ok = await confirmModal(t('common.delete') + '?', { danger: true });
        if (!ok) return;
        const tp = testPrints.find(x => x.id === btn.dataset.testId);
        testPrints = testPrints.filter(x => x.id !== btn.dataset.testId);
        // Restore filament weight when deleting a test print
        if (tp && tp.weightUsed > 0) {
          item.weight = (item.weight || 0) + tp.weightUsed;
        }
        saveAll();
        modal.querySelector('#testPrintList').innerHTML = listHtml();
        renderInventory();
      });
    },
    onSave(modal) {
      const date      = modal.querySelector('#tpDate').value || todayStr;
      const machineId = modal.querySelector('#tpMachine').value || null;
      const testType  = modal.querySelector('#tpType').value || 'other';
      const result    = modal.querySelector('#tpResult').value || 'good';
      const printTemp = parseFloat(modal.querySelector('#tpPrintTemp').value) || null;
      const bedTemp   = parseFloat(modal.querySelector('#tpBedTemp').value) || null;
      const speed     = parseFloat(modal.querySelector('#tpSpeed').value) || null;
      const notes     = modal.querySelector('#tpNotes').value.trim();
      const weightUsed = parseFloat(modal.querySelector('#tpWeight').value) || 0;
      const newTp = { id: uid('TP'), spoolId: itemId, date, machineId, testType, result, printTemp, bedTemp, speed, notes, weightUsed };
      testPrints.unshift(newTp);
      if (weightUsed > 0) {
        item.weight = Math.max(0, item.weight - weightUsed);
        if (!item.usageHistory) item.usageHistory = [];
        item.usageHistory.unshift({ orderId: newTp.id, project: `Test print (${testType})`, weightUsed, date });
        if (item.usageHistory.length > 200) item.usageHistory.length = 200;
      }
      saveAll();
      renderInventory();
      toast(t('inv.test_saved'), 'success');
      return true;
    }
  });
}

/* ============================================================
   Auto filament deduction (on completion)
   ============================================================ */
/* WHAT A FINISHED JOB TAKES OFF THE SHELF LIVES IN lib/order-deduction.js.
 *
 * The arithmetic used to be here, reading `inventory`, `consumables`,
 * `machines` and `settings` off the renderer's globals and calling `toast()`
 * and `renderInventory()` in the middle of itself. That put it out of reach of
 * the Mac app, whose board could not accept a card dropped on "completed": the
 * move is shared, but the shelf it empties was not, and a completion that
 * silently failed to deduct would be worse than no drag at all.
 *
 * What stayed here is the shop's globals, the shop's language, and the redraw.
 */

/** The module, however this file happens to be loaded.
 *
 *  The cache hangs off the function rather than a `let` beside it because
 *  `isLowStock` is defined 2,000 lines above and is called during the first
 *  render — a `let` here would still be in its temporal dead zone. */
function Deduction() {
  if (Deduction.cached) return Deduction.cached;
  if (typeof globalThis !== 'undefined' && globalThis.KhaytOrderDeduction) {
    Deduction.cached = globalThis.KhaytOrderDeduction;
    return Deduction.cached;
  }
  try { Deduction.cached = require('../lib/order-deduction.js'); } catch (e) { Deduction.cached = null; }
  return Deduction.cached;
}

/** The module names its messages; this file knows the shop's language. */
function showDeductionNotices(notices) {
  for (const n of notices || []) {
    switch (n.code) {
      case 'filament_deducted':
        toast(t('inv.deducted_summary', n.params), 'info', 2600); break;
      case 'filament_deducted_low':
        toast(t('inv.deducted_summary_low', n.params), 'warning', 4200); break;
      case 'consumable_low':
        toast(`${t('cons.low')}: ${n.params.name}`, 'warning', 3000); break;
      case 'packaging_low':
        toast(`📦 ${t('cons.low')}: ${n.params.name}`, 'warning', 3000); break;
      case 'packaging_deducted':
        toast(t('cons.packaging_deducted'), 'info', 2200); break;
      default:
        console.warn('[order-deduction] no message for', n.code);
    }
  }
}

/** Save and redraw whatever the deduction actually changed. */
function runDeductionEffects(effects) {
  for (const e of effects || []) {
    switch (e.type) {
      case 'save': saveAll(); break;
      case 'render_inventory': renderInventory(); break;
      case 'render_consumables': renderConsumables(); break;
      default: console.warn('[order-deduction] no handler for effect', e.type);
    }
  }
}

/** The context the rules read the shop through. */
function deductionContext() {
  return {
    settings,
    inventory,
    consumables,
    machines: typeof machines !== 'undefined' ? machines : [],
    today: localDateStr(),
  };
}

function deductFilamentForOrder(order, { skipRender = false } = {}) {
  // ── WHAT THE JOB REALLY USED, WHERE ANYTHING KNOWS IT ────────────────────
  //
  // `actualGrams` scales every part's claim to the figure on the record.
  // Absent — every job finished before a shop started recording them — the
  // estimate stands exactly as it always has, which is what `deductForOrder`
  // has done for every deduction Khayt has ever made.
  //
  // It has taken this since #978 and nothing passed it: that change was about
  // FAILED prints, where the grams go through `deductActual` instead, and it
  // left completions where they were on purpose. What has changed since is
  // that a completion can now BE measured — `promptActuals` writes the figure
  // onto the order before these effects run, and the Mac app's own sheet does
  // the same — so the number exists and nothing was spending it. A shop whose
  // print used 260 g against a 160 g quote was short 100 g on its shelf, every
  // time, with nothing to reconcile it.
  //
  // MEASURED OR TYPED, both count. Whether a printer read the figure or the
  // shop did decides whether it is evidence about an ESTIMATE — which is what
  // the variance reports ask — and not what left the shelf. What left the
  // shelf left it however the shop found out.
  const out = Deduction().deductForOrder(order, { ...deductionContext(), actualGrams: order.actualWeight },
                                         { skipRender });
  showDeductionNotices(out.notices);
  runDeductionEffects(out.effects);
}

/* Feature 6: Deduct packaging consumables when order completes */
function deductPackagingConsumables(order) {
  const out = Deduction().deductPackaging(order, { consumables });
  showDeductionNotices(out.notices);
  runDeductionEffects(out.effects);
}

/** True when this spool is at or below its reorder point.
 *
 *  The rule moved to lib/order-deduction.js with the deduction itself, so the
 *  banner, the row badge, the reorder list, the Mac app and the deduction can
 *  never disagree about the same spool. */
function isLowStockShared(item) {
  return Deduction().isLowStock(item, settings);
}

/* ============================================================
   Non-filament consumables (glue, isopropyl, sandpaper, etc.)
   ============================================================ */
// The category currently filtered to. '' is All. Held here rather than read off
// the <select> so a re-render cannot lose it, and reconciled against what
// actually exists on every draw — see resolveSelection().
let consCategoryFilter = '';

/** Change the filter and redraw. Exported — wire-events.js is a separate IIFE. */
function setConsCategoryFilter(v) {
  consCategoryFilter = String(v == null ? '' : v);
  renderConsumables();
}

/** Fill the filter picker from the items themselves, and keep the selection honest. */
function renderConsCategoryFilter() {
  const sel = $('#consCategoryFilter');
  if (!sel || typeof KhaytConsumableCategories === 'undefined') return;
  const CC = KhaytConsumableCategories;
  // A category the shop just emptied must not stay selected, or the list goes
  // blank under a heading still naming it — which reads as data loss.
  consCategoryFilter = CC.resolveSelection(consumables, consCategoryFilter);
  const cats = CC.categories(consumables);
  // Nothing to choose between until there are at least two groups.
  if (cats.length < 2) { sel.style.display = 'none'; sel.innerHTML = ''; return; }
  sel.style.display = '';
  const all = `<option value="">${escapeHtml(t('cons.cat_all') || 'All categories')} (${consumables.length})</option>`;
  sel.innerHTML = all + cats.map((c) => {
    const label = c.key === CC.UNCATEGORISED ? (t('cons.cat_none') || 'Uncategorised') : c.label;
    const value = c.key === CC.UNCATEGORISED ? CC.UNCATEGORISED : c.label;
    const on = CC.resolveSelection(consumables, consCategoryFilter) === value ? ' selected' : '';
    return `<option value="${escapeHtml(value)}"${on}>${escapeHtml(label)} (${c.count})</option>`;
  }).join('');
}

function renderConsumables() {
  const el = $('#consumablesTable tbody');
  if (!el) return;
  renderConsCategoryFilter();
  if (consumables.length === 0) {
    el.innerHTML = `<tr><td colspan="5" class="empty-state">${escapeHtml(t('cons.empty'))}</td></tr>`;
    return;
  }
  const shown = (typeof KhaytConsumableCategories !== 'undefined')
    ? KhaytConsumableCategories.filterByCategory(consumables, consCategoryFilter)
    : consumables;
  if (shown.length === 0) {
    // Only reachable if a filter is on, since resolveSelection() drops a stale
    // one — so say which filter, and offer the way out.
    el.innerHTML = `<tr><td colspan="5" class="empty-state">${escapeHtml(t('cons.cat_empty') || 'Nothing in this category.')}
      <button class="btn small ghost" data-act="cons-cat-all" style="margin-inline-start:10px;">${escapeHtml(t('cons.cat_all') || 'All categories')}</button></td></tr>`;
    return;
  }
  el.innerHTML = shown.map(c => {
    const low = c.minStock > 0 && c.stock <= c.minStock;
    const usageHint = c.usagePerHour > 0
      ? `<div style="font-size:10.5px; color:var(--primary); margin-top:1px;">${escapeHtml(t('cons.usage_per_hour'))}: ${c.usagePerHour} / h</div>`
      : '';
    // Shown only when not already filtered to it — the heading says it otherwise.
    const catChip = (c.category && !consCategoryFilter)
      ? `<span style="font-size:10px; background:var(--bg-elev); color:var(--text-dim); padding:1px 6px; border-radius:6px; margin-inline-start:6px; vertical-align:middle;">${escapeHtml(c.category)}</span>`
      : '';
    const packagingBadge = c.isPackaging
      ? `<span style="font-size:10px; background:rgba(251,146,60,0.18); color:var(--warning); padding:1px 6px; border-radius:6px; margin-inline-start:6px; vertical-align:middle;">📦 ${escapeHtml(t('cons.packaging_badge'))}</span>`
      : '';
    return `
      <tr${low ? ' style="background:rgba(245,166,35,0.08);"' : ''}>
        <td><strong>${escapeHtml(c.name)}</strong>${catChip}${packagingBadge}${low ? ` <span style="color:var(--low-stock); font-size:11px;">· ${escapeHtml(t('cons.low'))}</span>` : ''}${usageHint}</td>
        <td style="font-variant-numeric:tabular-nums;">${c.stock} ${escapeHtml(c.unit || '')}</td>
        <td style="font-variant-numeric:tabular-nums;">${c.minStock > 0 ? c.minStock + ' ' + escapeHtml(c.unit || '') : '—'}</td>
        <td style="font-variant-numeric:tabular-nums;">${c.cost > 0 ? fmtPrice(c.cost) : '—'}</td>
        <td style="white-space:nowrap;">
          <button class="btn small" data-act="edit-cons" data-id="${c.id}" style="margin-inline-end:4px;">${escapeHtml(t('common.edit'))}</button>
          <button class="btn danger small" data-act="del-cons" data-id="${c.id}">${escapeHtml(t('common.delete'))}</button>
        </td>
      </tr>`;
  }).join('');
}

function openConsumableEditor(id) {
  const existing = id ? consumables.find(c => c.id === id) : null;
  const draft = existing
    ? { ...existing }
    : { id: uid('CNS'), name: '', stock: 0, unit: '', cost: 0, minStock: 0, usagePerHour: 0, isPackaging: false };

  const bodyHtml = `
    <label>${escapeHtml(t('cons.name'))}</label>
    <input type="text" data-f="name" value="${escapeHtml(draft.name)}" placeholder="${escapeHtml(t('cons.name_ph'))}">
    <div class="inline-pair" style="margin-top:12px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('cons.stock'))}</label>
        <input type="number" data-f="stock" value="${draft.stock}" min="0" step="0.1">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('cons.unit'))}</label>
        <input type="text" data-f="unit" value="${escapeHtml(draft.unit)}" placeholder="pcs / ml / g">
      </div>
      <div>
        <label>${escapeHtml(t('cons.category') || 'Category')}</label>
        <!-- A free-text field with suggestions, not a fixed list: a shop's shelves
             are its own, and a closed list would need managing before it could be
             used. Matching is case- and space-insensitive (lib/consumable-categories.js),
             so picking a suggestion and retyping it land in the same place. -->
        <input type="text" data-f="category" list="consCategoryList" value="${escapeHtml(draft.category || '')}" placeholder="${escapeHtml(t('cons.category_ph') || 'e.g. Fasteners')}">
        <datalist id="consCategoryList">${
          (typeof KhaytConsumableCategories !== 'undefined'
            ? KhaytConsumableCategories.suggestions(consumables) : [])
            .map((c) => `<option value="${escapeHtml(c)}"></option>`).join('')
        }</datalist>
      </div>
    </div>
    <div class="inline-pair" style="margin-top:12px;">
      <div>
        <label style="margin-top:0;">${escapeHtml(t('cons.cost'))} (${currencySymbol()})</label>
        <input type="number" data-f="cost" value="${draft.cost}" min="0" step="0.01">
      </div>
      <div>
        <label style="margin-top:0;">${escapeHtml(t('cons.min_stock'))}</label>
        <input type="number" data-f="minStock" value="${draft.minStock}" min="0" step="1">
      </div>
    </div>
    <div style="margin-top:12px; padding:10px 12px; background:rgba(255,255,255,0.04); border-radius:var(--radius-sm); border:1px solid var(--border-soft);">
      <label style="margin-top:0; font-size:12px; font-weight:600;">${escapeHtml(t('cons.usage_per_hour'))} <span style="font-weight:400; color:var(--text-muted);">(${escapeHtml(t('cons.auto_deducted'))})</span></label>
      <input type="number" id="consUsagePerHour" data-f="usagePerHour" value="${draft.usagePerHour || 0}" min="0" step="0.01" placeholder="0 = disabled">
    </div>
    <label style="margin-top:12px; display:flex; align-items:center; gap:8px; cursor:pointer;">
      <input type="checkbox" id="consIsPackaging" style="width:auto; margin:0;" ${draft.isPackaging ? 'checked' : ''}>
      <span>📦 ${escapeHtml(t('cons.is_packaging'))}</span>
    </label>`;

  openFormModal({
    title: existing ? t('cons.edit_title') : t('cons.add_title'),
    saveLabel: t('common.save'),
    bodyHtml,
    onMount(modal) {
      modal.querySelectorAll('[data-f]').forEach(inp => {
        inp.addEventListener('input', () => { draft[inp.dataset.f] = inp.value; });
      });
    },
    onSave(modal) {
      const name = draft.name?.trim ? draft.name.trim() : '';
      if (!name) { toast(t('cons.name_ph'), 'error'); return false; }
      draft.name         = name;
      draft.stock        = Math.max(0, num(draft.stock, 0));
      draft.cost         = Math.max(0, num(draft.cost, 0));
      draft.minStock     = Math.max(0, num(draft.minStock, 0));
      draft.unit         = (draft.unit || '').trim();
      draft.category     = (draft.category || '').trim();
      draft.usagePerHour = Math.max(0, num(draft.usagePerHour, 0));
      draft.isPackaging  = !!(modal.querySelector('#consIsPackaging')?.checked);
      if (existing) {
        Object.assign(existing, draft);
      } else {
        consumables.push(draft);
      }
      saveAll();
      renderConsumables();
      toast(t('cons.saved'), 'success');
      return true;
    }
  });
}

function deleteConsumable(id) {
  const c = consumables.find(x => x.id === id);
  if (!c) return;
  confirmModal(`${t('common.delete')} "${c.name}"?`, { danger: true }).then(ok => {
    if (!ok) return;
    consumables = consumables.filter(x => x.id !== id);
    saveAll();
    renderConsumables();
    toast(t('cons.deleted'), 'success');
  });
}

/* ============================================================
   Supplier / Vendor database
   ============================================================ */
const SUPPLIER_CATEGORIES = ['filament', 'hardware', 'tools', 'packaging', 'services', 'other'];

// Feature F3: Estimate days remaining for an inventory item based on recent usage history
function estimateDaysRemaining(item) {
  const hist = (item.usageHistory || []).filter(h => h.weightUsed > 0);
  if (!hist.length) return null;
  const cutoff = Date.now() - 30 * 86400000;
  const recent = hist.filter(h => new Date(h.date).getTime() >= cutoff);
  const totalUsed = recent.reduce((s, h) => s + (+h.weightUsed || 0), 0);
  const days = recent.length > 0 ? Math.min(30, (Date.now() - new Date(recent[recent.length-1]?.date || Date.now()).getTime()) / 86400000 + recent.length) : 30;
  const dailyRate = totalUsed / Math.max(days, 1);
  if (!(dailyRate > 0)) return null;
  // A non-numeric weight (CSV/legacy rows) is "unknown", not zero — return null
  // so the forecast shows nothing rather than a bogus "0 d" / "NaN d".
  const w = +item.weight;
  if (!Number.isFinite(w)) return null;
  return Math.round(w / dailyRate);
}

function renderSupplierReorderList() {
  const el = $('#supplierReorderList');
  if (!el) return;

  const lowItems = inventory.filter(isLowStock);

  if (lowItems.length === 0) {
    el.innerHTML = `<div style="display:flex;align-items:center;gap:8px;padding:10px 14px;background:rgba(34,197,94,0.08);border-radius:var(--radius);border:1px solid rgba(34,197,94,0.2);margin-bottom:12px;font-size:13px;color:var(--success);">
      ${_iIcoL('check', '✅')}${escapeHtml(t('inv.stock_ok') || 'All materials are above reorder levels')}
    </div>`;
    return;
  }

  const bySupplier = {};
  for (const item of lowItems) {
    const key = item.supplierId || '__unknown__';
    if (!bySupplier[key]) bySupplier[key] = [];
    bySupplier[key].push(item);
  }

  const groupHtml = Object.entries(bySupplier).map(([supId, items]) => {
    const sup = supId !== '__unknown__' ? suppliers.find(s => s.id === supId) : null;
    const supName = sup ? escapeHtml(sup.name) : escapeHtml(t('sup.unknown') || 'Unknown supplier');
    const phoneBtn = sup?.phone
      ? `<a href="https://wa.me/${encodeURIComponent(sup.phone.replace(/\D/g, ''))}" target="_blank" class="btn small ghost" style="font-size:11px;">📲 ${escapeHtml(sup.phone)}</a>`
      : '';
    const webBtn = sup?.website && safeHttpUrl(sup.website)
      ? `<a href="${safeHttpUrl(sup.website)}" target="_blank" rel="noopener noreferrer" class="btn small ghost" style="font-size:11px;">🌐 ${escapeHtml(t('sup.website') || 'Website')}</a>`
      : '';
    const itemRows = items.map(item => {
      const needed = Math.max(0, (item.reorderPoint ?? settings.lowStockThreshold ?? 200) * 2 - item.weight);
      return `<div style="display:flex;align-items:center;gap:8px;padding:5px 8px;background:var(--bg-elev);border-radius:var(--radius-sm);margin-bottom:4px;">
        <span style="width:10px;height:10px;border-radius:50%;background:${safeCssColor(item.color, '#888')};display:inline-block;flex-shrink:0;"></span>
        <span style="flex:1;font-size:12.5px;">${escapeHtml(item.material)}${item.brand ? ` — ${escapeHtml(item.brand)}` : ''}</span>
        <span style="font-size:11.5px;color:var(--danger);white-space:nowrap;">${Math.round(item.weight)}g left</span>
        <span style="font-size:11px;color:var(--text-muted);white-space:nowrap;">need ~${Math.round(needed)}g</span>
        <button class="btn small primary" data-act="reorder-item" data-id="${item.id}" style="font-size:11px;padding:2px 8px;">${escapeHtml(t('inv.reorder') || 'Order')}</button>
      </div>`;
    }).join('');

    return `<div style="margin-bottom:10px;">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
        <span style="font-size:12px;font-weight:700;color:var(--text);display:inline-flex;align-items:center;">${_iIcoL('factory', '🏭')}${supName}</span>
        ${sup?.leadDays ? `<span style="font-size:11px;color:var(--text-muted);">${sup.leadDays}d lead time</span>` : ''}
        ${phoneBtn}${webBtn}
      </div>
      ${itemRows}
    </div>`;
  }).join('');

  el.innerHTML = `
    <div class="card" style="border-inline-start:3px solid var(--warning);">
      <h3 class="card-head" style="margin-bottom:10px;color:var(--warning);">
        <span class="swatch" style="background:var(--warning);"></span>
        ${_iIcoL('alert', '⚠')}${escapeHtml(t('inv.reorder_list') || 'Reorder List')} <span style="background:var(--low-stock);color:#000;font-size:11px;padding:1px 6px;border-radius:10px;margin-inline-start:6px;">${lowItems.length}</span>
      </h3>
      ${groupHtml}
    </div>`;

  el.querySelectorAll('[data-act="reorder-item"]').forEach(btn => {
    btn.addEventListener('click', () => {
      const item = inventory.find(i => i.id === btn.dataset.id);
      if (item) openReorderModal(item.id);
    });
  });
}

function renderSuppliers() {
  const tbody = $('#suppliersTable tbody');
  if (!tbody) return;
  const filtered = supplierSearchTerm
    ? suppliers.filter(s => {
        const term = supplierSearchTerm.toLowerCase();
        return (s.name || '').toLowerCase().includes(term) ||
               (s.city || '').toLowerCase().includes(term) ||
               (s.category || '').toLowerCase().includes(term) ||
               (s.notes || '').toLowerCase().includes(term);
      })
    : suppliers;
  if (filtered.length === 0) {
    tbody.innerHTML = `<tr><td colspan="6" style="text-align:center; color:var(--text-muted); padding:16px;">${escapeHtml(t('sup.empty'))}</td></tr>`;
    return;
  }
  tbody.innerHTML = filtered.map(s => {
    const totalSpent = s.purchases ? s.purchases.reduce((sum, p) => sum + (+p.amount || 0), 0) : 0;
    return `<tr data-supplier-id="${escapeHtml(s.id)}">
      <td><strong>${escapeHtml(s.name)}</strong>${s.notes ? `<div style="font-size:11px;color:var(--text-muted);">${escapeHtml(s.notes)}</div>` : ''}</td>
      <td>${escapeHtml(t('sup.cat.' + (s.category || 'other')))}</td>
      <td>${s.phone ? `<button class="btn small ghost" data-act="sup-wa" data-id="${s.id}" title="WhatsApp">📲 ${escapeHtml(s.phone)}</button>` : '—'}</td>
      <td>${s.leadDays ? `${escapeHtml(String(s.leadDays))} ${escapeHtml(t('common.days'))}` : '—'}</td>
      <td style="font-variant-numeric:tabular-nums;">${totalSpent > 0 ? fmtPrice(totalSpent) : '—'}</td>
      <td>
        <button class="btn small" data-act="edit-sup" data-id="${s.id}">${escapeHtml(t('common.edit'))}</button>
        <button class="btn small" data-act="log-purchase" data-id="${s.id}">${escapeHtml(t('sup.log_purchase'))}</button>
        <button class="btn small ghost" data-act="sup-history" data-id="${s.id}">${escapeHtml(t('sup.history'))}</button>
        <button class="btn danger small" data-act="del-sup" data-id="${s.id}">${escapeHtml(t('common.delete'))}</button>
      </td>
    </tr>`;
  }).join('');

  // Render supplier price history chart below the table
  const hasPurchases = suppliers.some(s => s.purchases && s.purchases.length > 0);
  if (hasPurchases) renderSupplierPriceHistory();
}

function openSupplierEditor(id) {
  const sup = id ? suppliers.find(s => s.id === id) : null;
  const catOptions = SUPPLIER_CATEGORIES.map(c =>
    `<option value="${c}"${(!id && c === 'other') || (sup?.category === c) ? ' selected' : ''}>${escapeHtml(t('sup.cat.' + c))}</option>`
  ).join('');

  const bodyHtml = `
    <label>${escapeHtml(t('sup.name'))}</label>
    <input type="text" id="supNameInput" value="${escapeHtml(sup?.name || '')}" placeholder="${escapeHtml(t('sup.name_ph'))}">
    <label style="margin-top:12px;">${escapeHtml(t('sup.category'))}</label>
    <select id="supCatSelect">${catOptions}</select>
    <div class="inline-pair" style="margin-top:12px;">
      <div>
        <label>${escapeHtml(t('sup.phone'))}</label>
        <input type="tel" id="supPhoneInput" value="${escapeHtml(sup?.phone || '')}" placeholder="+966…">
      </div>
      <div>
        <label>${escapeHtml(t('sup.lead_time'))}</label>
        <input type="number" id="supLeadInput" min="0" step="1" value="${escapeHtml(String(sup?.leadDays || ''))}">
      </div>
    </div>
    <label style="margin-top:12px;">${escapeHtml(t('sup.website'))}</label>
    <input type="url" id="supWebInput" value="${escapeHtml(sup?.website || '')}" placeholder="https://…">
    <label style="margin-top:12px;">${escapeHtml(t('sup.price_list') || 'Price list (per kg)')}</label>
    <div id="supPriceList"></div>
    <button type="button" id="supAddPrice" class="btn ghost small" style="margin-top:6px;">+ ${escapeHtml(t('sup.add_price') || 'Add material price')}</button>
    <label style="margin-top:12px;">${escapeHtml(t('common.notes'))}</label>
    <textarea id="supNotesInput" rows="2" style="resize:vertical;">${escapeHtml(sup?.notes || '')}</textarea>`;

  openFormModal({
    title: sup ? t('sup.edit') : t('sup.add'),
    saveLabel: t('common.save'),
    bodyHtml,
    onMount(modal) {
      const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
      const listEl = modal.querySelector('#supPriceList');
      const row = (p) => {
        p = p || { material: '', pricePerKg: '' };
        const r = document.createElement('div');
        r.className = 'supPriceRow';
        r.style.cssText = 'display:flex;gap:6px;align-items:center;margin-bottom:6px;';
        r.innerHTML = `
          <input class="spMat" type="text" maxlength="60" placeholder="${escapeHtml(t('sup.price_material_ph') || 'Material (e.g. PLA)')}" value="${escapeHtml(p.material || '')}" style="flex:1;font-size:12.5px;">
          <input class="spPk" type="number" min="0" step="0.01" placeholder="0" value="${escapeHtml(p.pricePerKg != null && p.pricePerKg !== '' ? String(p.pricePerKg) : '')}" style="width:90px;font-size:12.5px;text-align:right;" title="${escapeHtml(cur)}/kg">
          <button type="button" class="btn danger small spDel" style="font-size:11px;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">✕</button>`;
        r.querySelector('.spDel').addEventListener('click', () => r.remove());
        return r;
      };
      (sup?.priceList || []).forEach((p) => listEl.appendChild(row(p)));
      modal.querySelector('#supAddPrice').addEventListener('click', () => listEl.appendChild(row()));
    },
    onSave(modal) {
      const name = document.getElementById('supNameInput').value.trim();
      if (!name) { toast(t('sup.name_required'), 'error'); return false; }
      const priceList = Array.from((modal || document).querySelectorAll('.supPriceRow')).map((r) => ({
        material: r.querySelector('.spMat').value.trim(),
        pricePerKg: Math.max(0, num(r.querySelector('.spPk').value, 0)),
      })).filter((p) => p.material && p.pricePerKg > 0);
      const data = {
        name,
        category: document.getElementById('supCatSelect').value,
        phone:    document.getElementById('supPhoneInput').value.trim(),
        leadDays: num(document.getElementById('supLeadInput').value, 0) || null,
        website:  document.getElementById('supWebInput').value.trim(),
        notes:    document.getElementById('supNotesInput').value.trim(),
        priceList,
      };
      if (sup) {
        Object.assign(sup, data);
      } else {
        suppliers.push({ id: uid('sup'), purchases: [], ...data });
      }
      saveAll();
      renderSuppliers();
      toast(t('sup.saved'), 'success');
      return true;
    }
  });
}

function openLogPurchaseModal(supplierId) {
  const sup = suppliers.find(s => s.id === supplierId);
  if (!sup) return;
  const today = localDateStr();

  const bodyHtml = `
    <p style="font-size:13px; font-weight:600; margin:0 0 12px;">${escapeHtml(sup.name)}</p>
    <label>${escapeHtml(t('sup.purchase_date'))}</label>
    <input type="date" id="purchDateInput" value="${today}">
    <label style="margin-top:12px;">${escapeHtml(t('sup.purchase_amount'))} (${currencySymbol()})</label>
    <input type="number" id="purchAmtInput" min="0" step="0.01" placeholder="0.00">
    <label style="margin-top:12px;">${escapeHtml(t('sup.purchase_item'))}</label>
    <input type="text" id="purchItemInput" placeholder="${escapeHtml(t('sup.purchase_item_ph'))}">
    <label style="margin-top:12px;">${escapeHtml(t('common.notes'))}</label>
    <input type="text" id="purchNotesInput" placeholder="${escapeHtml(t('sup.purchase_notes_ph'))}">
    <div class="inline-pair" style="margin-top:12px;">
      <div>
        <label style="margin:0;">${escapeHtml(t('sup.unit_price'))}</label>
        <input type="number" id="pur_unitPrice" min="0" step="0.01" placeholder="0.00">
      </div>
      <div>
        <label style="margin:0;">${escapeHtml(t('sup.quantity'))}</label>
        <input type="number" id="pur_quantity" min="0" step="1" placeholder="1" value="1">
      </div>
    </div>
    <div class="inline-pair" style="margin-top:12px;">
      <div>
        <label style="margin:0;">${escapeHtml(t('sup.unit'))}</label>
        <select id="pur_unit">
          ${['spool','kg','g','L','piece','roll','box'].map(u => `<option value="${u}">${u}</option>`).join('')}
        </select>
      </div>
      <div>
        <label style="margin:0;">${escapeHtml(t('sup.material_type'))}</label>
        <input type="text" id="pur_materialType" placeholder="PLA, PETG, Resin…">
      </div>
    </div>`;

  openFormModal({
    title: t('sup.log_purchase'),
    saveLabel: t('common.save'),
    bodyHtml,
    onSave() {
      const amt = num(document.getElementById('purchAmtInput').value, 0);
      if (amt <= 0) { toast(t('sup.amount_required'), 'error'); return false; }
      if (!sup.purchases) sup.purchases = [];
      sup.purchases.unshift({
        id:           uid('pch'),
        date:         document.getElementById('purchDateInput').value,
        amount:       amt,
        item:         document.getElementById('purchItemInput').value.trim(),
        notes:        document.getElementById('purchNotesInput').value.trim(),
        unitPrice:    parseFloat(document.getElementById('pur_unitPrice')?.value)  || null,
        quantity:     parseFloat(document.getElementById('pur_quantity')?.value)   || 1,
        unit:         document.getElementById('pur_unit')?.value                    || 'spool',
        materialType: document.getElementById('pur_materialType')?.value?.trim()   || '',
      });
      saveAll();
      renderSuppliers();
      toast(t('sup.purchase_saved'), 'success');
      return true;
    }
  });
}

function openSupplierHistory(supplierId) {
  const sup = suppliers.find(s => s.id === supplierId);
  if (!sup) return;
  const purchases = sup.purchases || [];
  const totalSpent = purchases.reduce((sum, p) => sum + (+p.amount || 0), 0);

  const rowsHtml = purchases.length === 0
    ? `<p style="color:var(--text-muted); font-size:13px; margin:12px 0;">${escapeHtml(t('sup.history_empty'))}</p>`
    : `<div class="table-wrap" style="margin-top:12px;">
        <table>
          <thead><tr>
            <th>${escapeHtml(t('sup.hist_date'))}</th>
            <th>${escapeHtml(t('sup.hist_item'))}</th>
            <th>${escapeHtml(t('sup.hist_amount'))}</th>
            <th>${escapeHtml(t('common.notes'))}</th>
          </tr></thead>
          <tbody>
            ${purchases.map(p => `
              <tr>
                <td style="white-space:nowrap; font-size:12px; color:var(--text-dim);">${escapeHtml(p.date || '')}</td>
                <td>${escapeHtml(p.item || '')}</td>
                <td style="font-weight:600; font-variant-numeric:tabular-nums; white-space:nowrap;">${fmtPrice(p.amount || 0)}</td>
                <td style="font-size:12px; color:var(--text-muted);">${escapeHtml(p.notes || '')}</td>
              </tr>`).join('')}
          </tbody>
        </table>
      </div>
      <div style="margin-top:10px; text-align:right; font-weight:600; font-size:14px;">
        ${escapeHtml(t('sup.hist_total'))}: ${fmtPrice(totalSpent)}
      </div>`;

  openFormModal({
    title: `${escapeHtml(sup.name)} — ${t('sup.history')}`,
    noSave: true,
    sizeLg: true,
    bodyHtml: `
      <p style="font-size:12px; color:var(--text-muted); margin:0 0 4px;">${escapeHtml(t('sup.cat.' + (sup.category || 'other')))}</p>
      ${rowsHtml}`,
  });
}

async function deleteSupplier(id) {
  const sup = suppliers.find(s => s.id === id);
  if (!sup) return;
  const ok = await confirmModal(`${t('common.delete')} "${sup.name}"?`, { danger: true });
  if (!ok) return;
  suppliers = suppliers.filter(s => s.id !== id);
  // Null-out references so nothing points at a supplier that no longer exists (undo relinks).
  const unlinked = [];
  for (const it of inventory) { if (it.supplierId === id) { unlinked.push(it); it.supplierId = null; } }
  for (const po of purchaseOrders) { if (po.supplierId === id) { unlinked.push(po); po.supplierId = null; } }
  saveAll();
  renderSuppliers();
  toast(t('sup.deleted'), 'success', 5000, {
    undo: () => {
      suppliers.push(sup);
      for (const r of unlinked) r.supplierId = id;
      saveAll();
      renderSuppliers();
    },
  });
}

/* ============================================================
   Catalog — products with photos, multi-part, "Quote this"
   ============================================================ */
function getProductStats(productId) {
  const orders = printLog.filter(o => o.productId === productId);
  const completed = orders.filter(o => o.status === 'completed');
  return {
    count: orders.length,
    completedCount: completed.length,
    revenue: completed.reduce((s, o) => s + orderNetRevenueBase(o), 0),
    lastDate: orders[0]?.date || null
  };
}

function renderCatalog() {
  /* Show Publish only when there is somewhere to publish to.
   *
   * The action itself lives in Settings and always did; this is the same modal
   * reached from the screen it is about. Hidden rather than disabled, because a
   * shop with no cloud has nothing to learn from a greyed-out button. */
  const pubBtn = document.querySelector('#btnCatalogPublish');
  if (pubBtn) {
    const c = (typeof settings !== 'undefined' && settings && settings.cloud) || {};
    const owner = (c.role || 'owner') === 'owner';
    pubBtn.classList.toggle('hidden', !(c.enabled && c.url && c.shopId && owner));
  }

  const grid = $('#catalogGrid');
  if (!grid) return; // Catalog section is dropped in the Bed Ready flavor.
  const term = (catalogSearchTerm || '').toLowerCase().trim();
  let filtered = products;
  if (term) {
    filtered = products.filter(p =>
      (p.nameEn || '').toLowerCase().includes(term) ||
      (p.nameAr || '').toLowerCase().includes(term) ||
      (p.description || '').toLowerCase().includes(term) ||
      // The group and the category are how a catalogue of hundreds is searched.
      // Leaving them out meant typing "Saudi Kings" into the box found nothing,
      // while the chip beside it found all seven.
      productGroupOf(p).toLowerCase().includes(term) ||
      productCategoryOf(p).toLowerCase().includes(term)
    );
  }
  /* Both axes narrow at once: "the busts in the Saudi Kings" is a real question
   * and each on its own is not an answer to it. */
  renderCatalogFilters();
  if (catalogGroupFilter === CAT_UNFILED) filtered = filtered.filter((p) => !productGroupOf(p));
  else if (catalogGroupFilter) filtered = filtered.filter((p) => productGroupOf(p).toLowerCase() === catalogGroupFilter.toLowerCase());
  if (catalogCatFilter === CAT_UNFILED) filtered = filtered.filter((p) => !productCategoryOf(p));
  else if (catalogCatFilter) filtered = filtered.filter((p) => productCategoryOf(p).toLowerCase() === catalogCatFilter.toLowerCase());

  if (products.length === 0) {
    grid.innerHTML = `<div class="empty-state" style="grid-column: 1 / -1;">${escapeHtml(t('cat.empty'))}</div>`;
    return;
  }
  if (filtered.length === 0) {
    grid.innerHTML = `<div class="empty-state" style="grid-column: 1 / -1;">${escapeHtml(t('cat.empty_search'))}</div>`;
    return;
  }

  // Precompute stats for all products in one pass to avoid O(n²) scan
  const productStatsMap = new Map();
  for (const o of printLog) {
    if (!o.productId) continue;
    let s = productStatsMap.get(o.productId);
    if (!s) { s = { count: 0, completedCount: 0, revenue: 0, lastDate: null }; productStatsMap.set(o.productId, s); }
    s.count++;
    if (o.status === 'completed') { s.completedCount++; s.revenue += orderNetRevenueBase(o); }
    if (!s.lastDate || o.date > s.lastDate) s.lastDate = o.date;
  }

  grid.innerHTML = filtered.map(p => {
    const stats = productStatsMap.get(p.id) || { count: 0, completedCount: 0, revenue: 0, lastDate: null };
    const displayName = localName(p);
    // The shop's other content language, not "whichever of English and Arabic
    // isn't showing" — a German-and-French shop had a blank line under every
    // product, because nameAr is a field it has never filled in.
    const altName     = altLocalName(p);
    const partsCount = (p.parts || []).length;
    const partsLabel = partsCount === 1 ? t('cat.part') : t('cat.parts');
    const printedLabel = stats.count > 0 ? t('cat.printed_n', { n: stats.count }) : t('cat.never_printed');
    const lastLabel = stats.lastDate ? t('cat.last', { date: stats.lastDate }) : '';
    const photo = p.thumbnail && safeImageSrc(p.thumbnail)
      ? `<img src="${safeImageSrc(p.thumbnail)}" alt="${escapeHtml(displayName)}">`
      : `<div class="no-photo">
           <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>
           <span>${escapeHtml(t('cat.no_photo'))}</span>
         </div>`;

    return `
      <div class="product-card" data-id="${p.id}">
        <div class="product-photo">${photo}
          ${(() => {
            /* A quiet nudge, not a scolding.
             *
             * The question a customer asks of a listing is "is that a render or
             * is that what arrives", and getting it wrong is a refund. A shop
             * cannot answer it across a whole catalog by eye, so the grid says
             * which listings have no photograph of the real printed part —
             * only once there IS a picture, because "add a photo" is a
             * different and more obvious problem.
             */
            const imgs = KhaytProductImages.normalise(p).images;
            if (!imgs.length || KhaytProductImages.hasRealPhoto(p)) return '';
            return `<span class="product-norealphoto" title="${escapeHtml(t('pe.no_real_photo_hint') || 'None of these pictures is marked as a photo of the printed part.')}" style="position:absolute;inset-inline-start:6px;top:6px;background:var(--warning,#d97706);color:#fff;font-size:10px;padding:1px 5px;border-radius:4px;">${escapeHtml(t('pe.no_real_photo') || 'render only')}</span>`;
          })()}
        </div>
        <div class="product-body">
          <h4 class="product-name">${escapeHtml(displayName || '—')}</h4>
          ${altName ? `<div class="product-name-ar">${escapeHtml(altName)}</div>` : ''}
          <div class="product-meta">
            <span>${partsCount} ${escapeHtml(partsLabel)}</span>
            <span class="sep">·</span>
            <span>${escapeHtml(printedLabel)}</span>
            ${lastLabel ? `<span class="sep">·</span><span>${escapeHtml(lastLabel)}</span>` : ''}
          </div>
          ${stats.revenue > 0 ? `<div class="product-meta"><span style="color: var(--success);">${fmtPrice(stats.revenue)} ${escapeHtml(t('cat.revenue'))}</span></div>` : ''}
          ${(() => {
            /* Where it is filed and what it is — as buttons that FILTER, the
               same as on a print file's card. */
            const g = productGroupOf(p), c = productCategoryOf(p);
            if (!g && !c) return '';
            // The same icons the print-file library uses for the same two
            // ideas — a shop should not have to learn the vocabulary twice.
            const chip = (act, val, icon, title, on) =>
              `<button type="button" class="pf-folder ${on ? 'on' : ''}" data-act="${act}" data-val="${escapeHtml(val)}" title="${escapeHtml(title)}">${icon}${escapeHtml(val)}</button>`;
            return '<div class="pf-tags">'
              + (g ? chip('cat-filter-group', g, _iIco('folder'), t('plib.group') || 'Group',
                          catalogGroupFilter && catalogGroupFilter.toLowerCase() === g.toLowerCase()) : '')
              + (c ? chip('cat-filter-category', c, _iIco('board'), t('plib.category') || 'Category',
                          catalogCatFilter && catalogCatFilter.toLowerCase() === c.toLowerCase()) : '')
              + '</div>';
          })()}
        </div>
        <!-- Quoting is what a catalogue product is for. Delete was two along
             from it and permanently red; it is under the rule in the menu. -->
        <div class="act product-actions">
          <button class="btn success" data-act="cat-quote" data-id="${p.id}">${_iIco('forward')}${escapeHtml(t('cat.quote'))}</button>
          <details class="ovf act-end">
            <summary class="btn ghost small icon" role="button" aria-label="${escapeHtml(t('common.more') || 'More actions')}" title="${escapeHtml(t('common.more') || 'More actions')}">${_iIco('more', '', 16)}</summary>
            <div class="ovf-menu">
              <button data-act="cat-edit" data-id="${p.id}">${_iIco('pencil')}${escapeHtml(t('common.edit'))}</button>
              <div class="ovf-sep"></div>
              <button class="danger" data-act="cat-del" data-id="${p.id}">${_iIco('trash')}${escapeHtml(t('common.delete'))}</button>
            </div>
          </details>
        </div>
      </div>`;
  }).join('');
}

/** Append a product's parts to the current build (fresh ids + derived baseCost).
 *  Catalog parts store raw inputs only — baseCost is recomputed so it reflects
 *  current numbers and any later calculator changes. */
function appendProductParts(p) {
  for (const part of (p.parts || [])) {
    const partCopy = { ...part, id: uid('PRT') };
    if (!partCopy.material && partCopy.filamentId) {
      const inv = inventory.find(i => i.id === partCopy.filamentId);
      if (inv) partCopy.material = inv.material;
    }
    // baseCost is a LINE total (unit cost x qty) — build.js sums these against whole-order
    // revenue. The duplicate/reprint paths were fixed for this in beta.30; adding a
    // catalog product was the third site and was missed, so a 50-unit catalog line quoted
    // at 1/50 of its cost while every unit still printed.
    partCopy.baseCost = partTotalCost(partCopy);
    currentBuild.push(partCopy);
  }
}

function quoteFromProduct(productId) {
  const p = products.find(x => x.id === productId);
  if (!p) return;
  appendProductParts(p);
  currentBuildFromProductId = p.id;
  // Carry the product's BOM components (magnets/screws/packaging) into the order.
  currentComponents = Array.isArray(p.components) ? p.components.map(c => ({ ...c })) : [];
  currentAssemblyQty = p.assemblyQty > 0 ? p.assemblyQty : 1;
  if (p.defaultMargin !== undefined && p.defaultMargin !== '') {
    $('#margin').value = p.defaultMargin;
  }
  switchTab('calculator-tab');
  renderBuild();
  renderProductTierChips(p);
  toast(t('calc.quote.from_catalog', { name: localName(p) }), 'info');
}

/** Quote a bundle: append every member product's parts into one build. */
/** The products a package holds — a group's members if it follows one, else its
 *  own pinned list. lib/organise.js holds the rule; both callers use this. */
function bundleMembers(b) {
  const o = _org();
  const list = (typeof products !== 'undefined' && Array.isArray(products)) ? products : [];
  if (o) return o.setMembers(b, list);
  if (b && b.group) return list.filter((p) => productGroupOf(p).toLowerCase() === String(b.group).toLowerCase());
  const ids = new Set((b && b.productIds) || []);
  return list.filter((p) => ids.has(p.id));
}

function quoteFromBundle(bundleId) {
  const b = (settings.bundles || []).find(x => x.id === bundleId);
  if (!b) return;
  const members = bundleMembers(b);
  if (!members.length) { toast(t('bundle.empty') || 'This bundle has no products', 'error'); return; }
  members.forEach(appendProductParts);
  currentBuildFromProductId = null;
  switchTab('calculator-tab');
  renderBuild();
  toast((t('bundle.quoted', { name: b.name, n: members.length })) || `Quoted "${b.name}" (${members.length})`, 'info');
}

/** Manage bundles: list (quote/delete) + create a new named set of products. */
function openBundlesModal() {
  if (!settings.bundles) settings.bundles = [];
  const rows = settings.bundles.map((b) => {
    const members = bundleMembers(b);
    const names = members.map((p) => localName(p) || p.nameEn || p.id).filter(Boolean).join(' · ');
    return `
    <div class="card" data-bid="${escapeHtml(b.id)}" style="display:flex;justify-content:space-between;align-items:center;gap:8px;padding:8px 12px;margin-bottom:6px;">
      <div><div style="font-size:13px;font-weight:600;">${escapeHtml(b.name)}${b.group ? ` <span class="pf-part-tag">${escapeHtml(t('bundle.follows', { name: b.group }))}</span>` : ''}</div>
        <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(names || (t('bundle.empty') || 'empty'))}</div></div>
      <div style="display:flex;gap:6px;flex-shrink:0;">
        <button class="btn small success" data-bq="${escapeHtml(b.id)}">${escapeHtml(t('cat.quote') || 'Quote')}</button>
        <button class="btn small danger" data-bd="${escapeHtml(b.id)}">${escapeHtml(t('common.delete') || 'Delete')}</button>
      </div>
    </div>`;
  }).join('') || `<p style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('bundle.none') || 'No bundles yet.')}</p>`;

  /* THE GROUPS THAT ARE ALREADY PACKAGES AND NOBODY HAS SAID SO.
   *
   * A shop that has filed seven kings under "Saudi Kings" has already told
   * Khayt they belong together. Making them a package should not mean ticking
   * seven checkboxes and typing the name again — and a package built that way
   * FREEZES: an eighth king joins the group and the package stays at seven.
   *
   * One press instead, and the package FOLLOWS the group from then on. */
  const packaged = new Set((settings.bundles || []).map((b) => String(b.group || '').toLowerCase()).filter(Boolean));
  const offerable = catalogFiledUnder('group').names.filter(([name, n]) => n >= 2 && !packaged.has(name.toLowerCase()));
  const groupOffers = offerable.length ? `
    <label style="margin-top:14px;">${escapeHtml(t('bundle.from_groups') || 'Your groups')}</label>
    <div id="bundleGroups">${offerable.map(([name, n]) => `
      <div class="card" style="display:flex;justify-content:space-between;align-items:center;gap:8px;padding:8px 12px;margin-bottom:6px;">
        <div><div style="font-size:13px;font-weight:600;">${escapeHtml(name)}</div>
          <div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('bundle.n_products', { n: String(n) }))}</div></div>
        <button class="btn small" data-bgroup="${escapeHtml(name)}">${escapeHtml(t('bundle.make_package') || 'Make a package')}</button>
      </div>`).join('')}</div>` : '';
  const prodOpts = (products || []).map((p) => `<label style="display:flex;align-items:center;gap:6px;font-size:12.5px;padding:2px 0;cursor:pointer;"><input type="checkbox" class="bundleProd" value="${escapeHtml(p.id)}" style="width:auto;margin:0;"> ${escapeHtml(localName(p) || p.nameEn || p.id)}</label>`).join('')
    || `<p style="font-size:12px;color:var(--text-muted);">${escapeHtml(t('store.no_products') || 'Add products first')}</p>`;
  openFormModal({
    title: `🎁 ${t('bundle.title') || 'Bundles'}`,
    noSave: true,
    bodyHtml: `
      <div id="bundleList">${rows}</div>
      ${groupOffers}
      <hr style="border:none;border-top:1px solid var(--border-soft);margin:12px 0;">
      <label>${escapeHtml(t('bundle.new') || 'New bundle')}</label>
      <input id="bundleName" type="text" maxlength="80" placeholder="${escapeHtml(t('bundle.name_ph') || 'e.g. Desk set')}">
      <div style="max-height:180px;overflow-y:auto;border:1px solid var(--border-soft);border-radius:8px;padding:8px;margin-top:8px;">${prodOpts}</div>
      <button id="bundleCreate" class="btn primary small" type="button" style="margin-top:10px;">${escapeHtml(t('bundle.create') || 'Create bundle')}</button>
      <span id="bundleResult" style="font-size:12px;display:block;margin-top:8px;"></span>`,
    onMount(modal) {
      modal.querySelectorAll('[data-bq]').forEach((b) => b.addEventListener('click', () => {
        const id = b.dataset.bq;
        modal.closest('.modal-backdrop')?.querySelector('[data-act="cancel"]')?.click();
        quoteFromBundle(id);
      }));
      modal.querySelectorAll('[data-bd]').forEach((b) => b.addEventListener('click', async () => {
        if (!(await confirmModal(t('bundle.delete_q') || 'Delete this bundle?', { danger: true }))) return;
        settings.bundles = settings.bundles.filter((x) => x.id !== b.dataset.bd); saveAll();
        b.closest('[data-bid]')?.remove();
      }));
      modal.querySelectorAll('[data-bgroup]').forEach((b) => b.addEventListener('click', () => {
        const name = b.dataset.bgroup;
        // `group`, not a snapshot of ids: the package is the collection, and the
        // collection is allowed to grow.
        settings.bundles.push({ id: uid('BND'), name, group: name, createdAt: new Date().toISOString() });
        saveAll();
        openBundlesModal();
        toast(t('bundle.packaged', { name }) || `"${name}" can be quoted as one package`, 'success');
      }));
      modal.querySelector('#bundleCreate')?.addEventListener('click', () => {
        const name = modal.querySelector('#bundleName').value.trim();
        const ids = [...modal.querySelectorAll('.bundleProd:checked')].map((c) => c.value);
        const res = modal.querySelector('#bundleResult');
        if (!name || !ids.length) { res.textContent = '✗ ' + (t('bundle.need') || 'Name it and pick at least one product'); res.style.color = 'var(--danger)'; return; }
        settings.bundles.push({ id: uid('BND'), name, productIds: ids, createdAt: new Date().toISOString() });
        saveAll();
        openBundlesModal(); // refresh the list
      });
    },
  });
}

async function deleteProduct(productId) {
  const p = products.find(x => x.id === productId);
  if (!p) return;
  const ok = await confirmModal(t('pe.delete_q'), { danger: true });
  if (!ok) return;
  if (p.imagePath && window.hubAPI?.deleteProductImage) {
    try { await window.hubAPI.deleteProductImage(p.imagePath); } catch (_) {}
  }
  products = products.filter(x => x.id !== productId);
  // Clean up references: unlink orders and drop the product from any quote bundles (undo relinks).
  const unlinked = [];
  for (const o of printLog) { if (o.productId === productId) { unlinked.push(o); o.productId = null; } }
  const bundleHits = [];
  for (const b of (settings.bundles || [])) {
    if (Array.isArray(b.productIds) && b.productIds.includes(productId)) {
      bundleHits.push(b);
      b.productIds = b.productIds.filter(pid => pid !== productId);
    }
  }
  saveAll();
  renderCatalog();
  toast(t('pe.deleted'), 'success', 5000, {
    undo: () => {
      products.push(p);
      for (const o of unlinked) o.productId = productId;
      for (const b of bundleHits) if (Array.isArray(b.productIds) && !b.productIds.includes(productId)) b.productIds.push(productId);
      saveAll();
      renderCatalog();
    },
  });
}

/* ----- Product editor modal ----- */
// Default pricing for a catalog product: sum the calculator's per-part cost, apply the
// product's margin. Shared by the editor's live summary and its save (stored as basePrice).
function productDefaultPricing(d) {
  const partsCost = (d.parts || []).reduce((s, p) =>
    s + (typeof computePartBaseCost === 'function' ? computePartBaseCost(p) : (+p.baseCost || 0)), 0);
  // BOM: fold non-printed components into the assembly's unit cost.
  const compCost = (typeof computeComponentsCost === 'function')
    ? computeComponentsCost(d.components, typeof consumables !== 'undefined' ? consumables : []) : 0;
  const cost = partsCost + compCost;
  const margin = Math.max(0, num(d.defaultMargin, 30));
  const basePrice = +(cost * (1 + margin / 100)).toFixed(2);
  /* `basePrice` stays exactly what it has always been — cost plus margin — and
   * `price` is what the shop charges. Keeping both is the point: a shop that can
   * only see its rounded price cannot tell a healthy margin from a rounding
   * accident. */
  const fp = KhaytProductPrice.finalPrice(d, basePrice);
  return { cost: +cost.toFixed(2), basePrice, price: fp.final, priceSource: fp.source };
}

/* ── GROUPS AND CATEGORIES, shared with the print-file library ──────────────
 * lib/organise.js holds the rules; these are the catalogue's way in. An
 * accessor rather than a bare global: the Bed Ready flavour drops this screen
 * and reading the name directly is a ReferenceError waiting for whoever opens
 * it there. */
function _org() { return (typeof window !== 'undefined' && window.KhaytOrganise) || null; }

/** Every group or category in use across the catalogue AND the library — one
 *  shop, one set of names. Offering only this screen's is how the same
 *  collection gets typed twice and drifts into two. */
function organiseKnown(field) {
  const o = _org();
  const pool = (typeof products !== 'undefined' && Array.isArray(products) ? products : [])
    .concat(typeof printFiles !== 'undefined' && Array.isArray(printFiles) ? printFiles : []);
  if (o) return o.known(pool, field);
  const read = (r) => String((field === 'category' ? r.category : (r.group || r.folder)) || '').trim();
  return [...new Set(pool.map(read).filter(Boolean))].sort();
}

function organiseOptions(field) {
  return organiseKnown(field).map((n) => `<option value="${escapeHtml(n)}"></option>`).join('');
}

/** The fields to merge onto a product to file it. */
function organiseAssign(rec, patch) {
  const o = _org();
  if (!o) {
    const out = {};
    if (patch && 'group' in patch) { out.group = String(patch.group || '').trim(); out.folder = out.group; }
    if (patch && 'category' in patch) out.category = String(patch.category || '').trim();
    return out;
  }
  return o.assign(rec, patch, { group: organiseKnown('group'), category: organiseKnown('category') });
}

const productGroupOf = (p) => (_org() ? _org().groupOf(p) : String((p && (p.group || p.folder)) || '').trim());
const productCategoryOf = (p) => (_org() ? _org().categoryOf(p) : String((p && p.category) || '').trim());

/* Its own attribute, not a magic value — see renderer/printfiles.js.
 *
 * This was `'\u0000unfiled'` written into `data-val`, and the HTML tokenizer
 * replaces U+0000 in an attribute value with U+FFFD, so what came back off
 * `dataset` never equalled the sentinel. The Unfiled and Uncategorised chips
 * set a filter matching nothing, renderCatalogFilters reset it, and the grid
 * redrew identical to All.
 *
 * I fixed exactly this in the print-file library and wrote it fresh here the
 * same night, on the screen next door. */
const CAT_UNFILED = '\u2400unfiled';   // in code only; never written to markup
let catalogGroupFilter = '';
let catalogCatFilter = '';

/** Two filter values meaning the same thing. See sameFilter in printfiles.js:
 *  a bar chip carries the spelling used MOST and a card chip carries that
 *  record's own, so `===` meant pressing the lit chip on a "saudi kings" card
 *  replaced a filter set from the "Saudi Kings" bar instead of clearing it. */
const sameCatFilter = (a, b) => (a === CAT_UNFILED || b === CAT_UNFILED)
  ? a === b
  : String(a || '').toLowerCase() === String(b || '').toLowerCase();

/** Everything the OTHER filters leave standing — the search box included. */
function catalogRowsExcept(field) {
  const list = (typeof products !== 'undefined' && Array.isArray(products)) ? products : [];
  const term = (catalogSearchTerm || '').toLowerCase().trim();
  return list.filter((p) => {
    if (term && !((p.nameEn || '').toLowerCase().includes(term)
      || (p.nameAr || '').toLowerCase().includes(term)
      || (p.description || '').toLowerCase().includes(term)
      || productGroupOf(p).toLowerCase().includes(term)
      || productCategoryOf(p).toLowerCase().includes(term))) return false;
    if (field !== 'group') {
      if (catalogGroupFilter === CAT_UNFILED) { if (productGroupOf(p)) return false; }
      else if (catalogGroupFilter && productGroupOf(p).toLowerCase() !== catalogGroupFilter.toLowerCase()) return false;
    }
    if (field !== 'category') {
      if (catalogCatFilter === CAT_UNFILED) { if (productCategoryOf(p)) return false; }
      else if (catalogCatFilter && productCategoryOf(p).toLowerCase() !== catalogCatFilter.toLowerCase()) return false;
    }
    return true;
  });
}

/**
 * Counts for one axis, against everything EXCEPT that axis.
 *
 * These counted the whole catalogue while the grid narrows on three things at
 * once, so with a category on, a group chip said 7 and pressing it showed 2.
 * The print-file library got this right the same night; the catalogue did not.
 */
function catalogFiledUnder(field) {
  const o = _org();
  const read = field === 'category' ? productCategoryOf : productGroupOf;
  const pool = catalogRowsExcept(field);
  const names = o ? o.counts(pool, field) : (() => {
    const m = new Map();
    for (const p of pool) { const v = read(p); if (v) m.set(v, (m.get(v) || 0) + 1); }
    return [...m.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  })();
  let unfiled = 0;
  for (const p of pool) if (!read(p)) unfiled++;
  return { names, unfiled, total: pool.length };
}

/**
 * Draw the group and category chip bars above the grid.
 *
 * A filter that no longer matches anything is DROPPED rather than left on: a
 * shop that re-files the last product out of a group would otherwise be stuck
 * looking at an empty grid with no obvious way back.
 */
function renderCatalogFilters() {
  const host = $('#catalogFilters');
  if (!host) return;
  const list = (typeof products !== 'undefined' && Array.isArray(products)) ? products : [];
  if (catalogGroupFilter === CAT_UNFILED) { if (!list.some((p) => !productGroupOf(p))) catalogGroupFilter = ''; }
  else if (catalogGroupFilter && !list.some((p) => productGroupOf(p).toLowerCase() === catalogGroupFilter.toLowerCase())) catalogGroupFilter = '';
  if (catalogCatFilter === CAT_UNFILED) { if (!list.some((p) => !productCategoryOf(p))) catalogCatFilter = ''; }
  else if (catalogCatFilter && !list.some((p) => productCategoryOf(p).toLowerCase() === catalogCatFilter.toLowerCase())) catalogCatFilter = '';

  const bar = (field) => {
    const { names, unfiled, total } = catalogFiledUnder(field);
    if (!names.length) return '';
    const isCat = field === 'category';
    const active = isCat ? catalogCatFilter : catalogGroupFilter;
    const act = isCat ? 'cat-filter-category' : 'cat-filter-group';
    const chip = (val, label, n, on) =>
      `<button type="button" class="pf-folderchip ${on ? 'on' : ''}" data-act="${act}"`
      + (val === CAT_UNFILED ? ' data-unfiled="1"' : ` data-val="${escapeHtml(val)}"`)
      + `>${escapeHtml(label)}${n != null ? ` <span class="pf-tagchip-n">${n}</span>` : ''}</button>`;
    let html = chip('', t(isCat ? 'plib.all_cats' : 'cat.all_products') || 'All', total, !active);
    html += names.map(([f, n]) => chip(f, f, n, active && active.toLowerCase() === f.toLowerCase())).join('');
    if (unfiled) html += chip(CAT_UNFILED, t(isCat ? 'plib.uncategorised' : 'plib.unfiled') || 'Unfiled', unfiled, active === CAT_UNFILED);
    const label = t(isCat ? 'plib.filter_cats' : 'plib.filter_folders') || 'Filter';
    return `<div class="pf-folderbar" role="group" aria-label="${escapeHtml(label)}">${html}</div>`;
  };
  host.innerHTML = bar('group') + bar('category');
}

/** Toggle one axis of the catalogue filter. Pressing the chip that is already
 *  on clears it, so a filter is never a state you cannot get out of. */
/** What a catalogue filter chip means — `data-unfiled` is its own attribute,
 *  because a sentinel written into a value cannot survive the HTML parser. */
function catFilterValue(btn) {
  return btn && btn.dataset.unfiled ? CAT_UNFILED : ((btn && btn.dataset.val) || '');
}

function filterCatalogBy(field, value) {
  if (field === 'category') catalogCatFilter = sameCatFilter(catalogCatFilter, value) ? '' : value;
  else catalogGroupFilter = sameCatFilter(catalogGroupFilter, value) ? '' : value;
  renderCatalog();
}

function openProductEditor(productId = null) {
  const existing = productId ? products.find(p => p.id === productId) : null;
  const editing = !!existing;
  const draft = existing
    ? JSON.parse(JSON.stringify(existing))
    : {
        id: uid('PROD'),
        nameEn: '',
        nameAr: '',
        description: '',
        thumbnail: null,
        imagePath: null,
        defaultMargin: 30,
        priceTiers: [],
        parts: [],
        createdAt: localDateStr()
      };
  /* Every per-language field has to EXIST on the draft before the form is built.
   *
   * The [data-f] sync below writes a field only if the draft already has that
   * key — a whitelist, so a stray input cannot inject arbitrary properties. But
   * the draft is seeded with `nameEn`, `nameAr` and a plain `description`, while
   * the form's inputs are named from the shop's content languages:
   * `descriptionEn`, `name_de`, `description_tr`. None of those keys were on the
   * draft, so the guard rejected them and the typed value was thrown away in
   * silence.
   *
   * Reported as "I keep writing a description and save only to find it not
   * saved", and it was every description, in every shop — the name survived only
   * because `nameEn` happens to be one of the seeded keys. A shop writing German
   * lost its product NAMES the same way.
   *
   * migratePlain first, so a description written before the catalogue had
   * languages is carried into the shop's first one rather than being hidden
   * behind an empty new field.
   */
  KhaytContentLanguages.migratePlain(draft, 'description', typeof settings !== 'undefined' ? settings : null);
  /* Same reason, for the same guard: a product saved before groups existed has
   * neither key, so [data-f] would reject both and the shop would type a
   * category, save, and find it gone — exactly the bug described above. */
  if (draft.group == null) draft.group = '';
  if (draft.category == null) draft.category = '';
  for (const lang of KhaytContentLanguages.contentLangs(typeof settings !== 'undefined' ? settings : null)) {
    for (const base of ['name', 'description']) {
      const key = KhaytContentLanguages.fieldKey(base, lang);
      if (!(key in draft)) draft[key] = '';
    }
  }

  if (!draft.priceTiers) draft.priceTiers = [];
  if (!Array.isArray(draft.components)) draft.components = [];

  // Files to unlink only if the shop SAVES — cancelling must leave a removed
  // document exactly where it was.
  const pendingDocDeletes = [];

  // Local mutable photo state for the modal
  let stagedThumbnail = draft.thumbnail || null;
  let stagedFullDataUrl = null; // only set if a new photo was picked

  /**
   * Every picture on this product, as a working list.
   *
   * The editor used to hold ONE thumbnail and one staged data URL, so picking a
   * new photo replaced the old and deleted it on save. A shop selling a printed
   * part needs a render, a photo of the real thing, a scale shot and a detail —
   * and had to choose one.
   *
   * `full` is set only for pictures added in THIS session; the ones already on
   * disk keep their path and are not rewritten.
   */
  KhaytProductImages.apply(draft);
  let stagedImages = (draft.images || []).map((img) => ({ ...img, full: null }));
  const removedImages = [];   // unlinked on save, not before — cancelling must not delete

  // Documents that belong to the PRODUCT, not to an order.
  //
  // Assembly instructions and safety sheets are properties of the thing being
  // made. Attached to an order's part they would have to be re-attached every
  // time somebody ordered the same product; attached here they follow every
  // order that names it, onto the work order the floor reads and the delivery
  // note that goes in the box.
  if (!Array.isArray(draft.docs)) draft.docs = [];
  const docsHtml = () => {
    if (!draft.docs.length) {
      return `<div class="empty-state" style="padding:12px;font-size:12px;">${escapeHtml(t('pdoc.none') || 'No documents. Assembly instructions or a safety sheet added here travel with every order for this product.')}</div>`;
    }
    return draft.docs.map((d, i) => `
      <div style="display:flex;gap:8px;align-items:center;margin-bottom:6px;">
        <span style="flex:1;font-size:12.5px;">${escapeHtml(d.originalName || d.filename)}</span>
        <label style="display:flex;align-items:center;gap:5px;margin:0;font-size:11.5px;color:var(--text-muted);white-space:nowrap;cursor:pointer;">
          <input type="checkbox" class="pdocPack" data-di="${i}" style="width:auto;margin:0;" ${d.packWithOrder === false ? '' : 'checked'}>
          ${escapeHtml(t('pdoc.pack') || 'include when shipped')}
        </label>
        <button class="btn small" data-act="open-pdoc" data-di="${i}" style="margin:0;">${escapeHtml(t('common.open') || 'Open')}</button>
        <button class="btn danger small" data-act="rm-pdoc" data-di="${i}" style="margin:0;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
      </div>`).join('');
  };

  // BOM: non-printed component rows (magnets, screws, inserts, packaging) referencing
  // consumables. One <select> of consumables + a per-assembly quantity.
  const componentsHtml = () => {
    if (!draft.components.length) return `<div class="empty-state" style="padding:12px;font-size:12px;">${escapeHtml(t('bom.no_components') || 'No components — this is a single printed item.')}</div>`;
    const opts = (cid) => (typeof consumables !== 'undefined' ? consumables : []).map(c =>
      `<option value="${escapeHtml(c.id)}"${c.id === cid ? ' selected' : ''}>${escapeHtml(c.name)}${c.unit ? ' (' + escapeHtml(c.unit) + ')' : ''}</option>`).join('');
    return draft.components.map((comp, i) => `
      <div class="bom-comp-row" data-ci="${i}" style="display:flex;gap:8px;align-items:center;margin-bottom:6px;">
        <select class="bom-comp-consumable" style="flex:1;margin:0;"><option value="">—</option>${opts(comp.consumableId)}</select>
        <input type="number" class="bom-comp-qty" value="${comp.qtyPerUnit != null ? comp.qtyPerUnit : 1}" min="0" step="1" style="width:90px;margin:0;" title="${escapeHtml(t('bom.qty_per_unit') || 'Qty per assembly')}">
        <button class="btn danger small" data-act="rm-component" data-ci="${i}" style="margin:0;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
      </div>`).join('');
  };

  const partsHtml = () => (draft.parts.length === 0
    ? `<div class="empty-state" style="padding:18px;">${escapeHtml(t('pe.no_parts'))}</div>`
    : draft.parts.map((part, i) => renderPartRow(part, i)).join(''));

  function renderPartRow(part, i) {
    const filamentOptions = inventory.map(it =>
      `<option value="${it.id}" ${part.filamentId === it.id ? 'selected' : ''}>${escapeHtml(it.material)}</option>`
    ).join('');
    return `
      <div class="part-row" data-pi="${i}">
        <div class="part-head">
          <h4>${escapeHtml(t('pe.part_n', { n: i + 1 }))}</h4>
          <button class="btn danger small" data-act="rm-part" data-pi="${i}">${escapeHtml(t('pe.remove_part'))}</button>
        </div>
        <!-- The print file this part comes from.
             A catalog part was born with printWeight 0 and printTime 0 and the
             shop typed both, while the print library held exactly those numbers
             — parsed out of the g-code at import. The order editor already had
             this picker and copied only the FILENAME. -->
        <div style="display:flex;gap:8px;align-items:flex-end;margin-bottom:8px;">
          <div style="flex:1;">
            <label>${escapeHtml(t('pe.print_file') || 'Print file')}</label>
            <select data-f="printFileId" class="part-printfile" data-pi="${i}">
              <option value="">${escapeHtml(t('pe.no_print_file') || '— none —')}</option>
              ${(typeof printFiles !== 'undefined' ? printFiles : []).map((f) =>
                `<option value="${escapeHtml(f.id)}"${part.printFileId === f.id ? ' selected' : ''}>${escapeHtml(f.name || f.originalName || f.id)}</option>`).join('')}
            </select>
          </div>
          <button class="btn small part-fill" data-pi="${i}" ${part.printFileId ? '' : 'disabled'}>${escapeHtml(t('pe.fill_from_file') || 'Fill from file')}</button>
        </div>
        <div class="pair-3">
          <div>
            <label>${escapeHtml(t('calc.part.name'))}</label>
            <input type="text" data-f="name" value="${escapeHtml(part.name || '')}">
          </div>
          <div>
            <label>${escapeHtml(t('calc.part.filament'))}</label>
            <select data-f="filamentId">${filamentOptions}</select>
          </div>
          <div>
            <label>${escapeHtml(t('calc.part.print_wt'))} (${escapeHtml(t('common.grams'))})</label>
            <input type="number" min="0" step="1" data-f="printWeight" value="${part.printWeight ?? 0}">
          </div>
          <div>
            <label>${escapeHtml(t('calc.machine.time'))} (${escapeHtml(t('common.hours'))})</label>
            <input type="number" min="0" step="0.1" data-f="printTime" value="${part.printTime ?? 0}">
          </div>
          <div>
            <label>${escapeHtml(t('calc.labor.prep'))} (${escapeHtml(t('common.hours'))})</label>
            <input type="number" min="0" step="0.1" data-f="prepTime" value="${part.prepTime ?? 0}">
          </div>
          <div>
            <label>${escapeHtml(t('calc.labor.post'))} (${escapeHtml(t('common.hours'))})</label>
            <input type="number" min="0" step="0.1" data-f="postTime" value="${part.postTime ?? 0}">
          </div>
        </div>
      </div>`;
  }

  /**
   * The picture strip. The first one is the primary: it is what the grid, the
   * storefront and the invoice use, so the order is a decision rather than an
   * accident of upload order.
   */
  const imagesHtml = () => `
    <div class="photo-uploader">
      <div class="photo-drop ${stagedImages.length ? 'has-photo' : ''}" data-act="pick-photo">
        ${stagedImages[0]
            ? `<img src="${stagedImages[0].thumbnail || ''}" alt="">`
            : `<span>${escapeHtml(t('pe.photo_drop'))}</span>`}
      </div>
      <div class="photo-actions">
        <button class="btn small" data-act="pick-photo">${escapeHtml(stagedImages.length ? (t('pe.photo_add') || 'Add another photo') : t('pe.photo'))}</button>
      </div>
    </div>
    ${stagedImages.length ? `
    <div id="productImageStrip" style="display:flex;gap:10px;flex-wrap:wrap;margin-top:10px;">
      ${stagedImages.map((img, i) => `
        <div style="width:120px;border:1px solid var(--border);border-radius:8px;padding:6px;${i === 0 ? 'outline:2px solid var(--primary);' : ''}">
          <img src="${escapeHtml(img.thumbnail || '')}" alt="" style="width:100%;height:74px;object-fit:cover;border-radius:5px;display:block;">
          <select class="pi-kind" data-id="${escapeHtml(img.id)}" style="width:100%;font-size:11px;margin-top:5px;padding:2px;">
            ${KhaytProductImages.KINDS.map((k) => `<option value="${k.key}"${img.kind === k.key ? ' selected' : ''} title="${escapeHtml(k.hint)}">${escapeHtml(t('pe.kind_' + k.key) || k.label)}</option>`).join('')}
          </select>
          <div style="display:flex;gap:4px;margin-top:4px;">
            ${i === 0
              ? `<span style="font-size:10px;color:var(--primary);flex:1;text-align:center;padding-top:3px;">${escapeHtml(t('pe.primary') || 'Main')}</span>`
              : `<button class="btn ghost small pi-primary" data-id="${escapeHtml(img.id)}" style="flex:1;font-size:10px;padding:2px;">${escapeHtml(t('pe.make_primary') || 'Make main')}</button>`}
            <button class="btn danger small pi-remove" data-id="${escapeHtml(img.id)}" style="font-size:10px;padding:2px 6px;" aria-label="${escapeHtml(t('pe.photo_remove'))}" title="${escapeHtml(t('pe.photo_remove'))}">×</button>
          </div>
        </div>`).join('')}
    </div>
    <p style="font-size:11px;color:var(--text-muted);margin:6px 0 0;">${escapeHtml(t('pe.kind_hint') || 'Say which pictures are photos of the real printed part. Customers are asking, and a render that looks like a photo is a refund.')}</p>` : ''}
    <input type="file" id="productPhotoInput" accept="image/jpeg,image/png,image/webp" multiple style="display:none;">
`;

  /* The languages this shop writes content in — one or two, and which ones.
   * A product saved before per-language descriptions carries `description` with
   * no language on it; folding it into the first content language is the only
   * reading that does not lose it. */
  const CONTENT_LANGS = KhaytContentLanguages.contentLangs(settings);
  KhaytContentLanguages.migratePlain(draft, 'description', settings);

  const bodyHtml = `
    <div id="productImagesBlock">${imagesHtml()}</div>

    <!-- Name and description, one field per language the shop writes in.
         It used to be nameEn + nameAr hard-coded, and a SINGLE description with
         no language on it at all — so the name could be bilingual and the
         paragraph a customer reads to decide could not. -->
    <div class="inline-pair" style="margin-top: 16px;">
      ${CONTENT_LANGS.map((lang) => `
      <div>
        <label>${escapeHtml(t('pe.name') || 'Name')} · ${escapeHtml(KhaytContentLanguages.languageName(lang))}</label>
        <input type="text" data-f="${escapeHtml(KhaytContentLanguages.fieldKey('name', lang))}"
               ${lang === 'ar' ? 'dir="rtl"' : ''}
               placeholder="${escapeHtml(t('pe.name_ph') || '')}"
               value="${escapeHtml(draft[KhaytContentLanguages.fieldKey('name', lang)] || '')}">
      </div>`).join('')}
    </div>

    <!-- HOW A CATALOGUE OF HUNDREDS IS FOUND IN.
         A GROUP is a set that belongs together — the seven Saudi Kings. A
         CATEGORY is what the thing IS. Both are shared with the print-file
         library through lib/organise.js, so a shop that has typed "Saudi Kings"
         on either screen is offered it on the other rather than typing a second
         spelling of one collection. -->
    <div class="inline-pair" style="margin-top: 12px;">
      <div>
        <label>${escapeHtml(t('plib.group') || 'Group')}</label>
        <input type="text" data-f="group" list="prodGroupList" maxlength="60"
               placeholder="${escapeHtml(t('plib.group_ph') || 'e.g. Saudi Kings')}"
               value="${escapeHtml(draft.group || '')}">
        <datalist id="prodGroupList">${organiseOptions('group')}</datalist>
      </div>
      <div>
        <label>${escapeHtml(t('plib.category') || 'Category')}</label>
        <input type="text" data-f="category" list="prodCatList" maxlength="60"
               placeholder="${escapeHtml(t('plib.category_ph') || 'e.g. Busts')}"
               value="${escapeHtml(draft.category || '')}">
        <datalist id="prodCatList">${organiseOptions('category')}</datalist>
      </div>
    </div>

    ${CONTENT_LANGS.map((lang) => `
    <label>${escapeHtml(t('pe.description'))} · ${escapeHtml(KhaytContentLanguages.languageName(lang))}</label>
    <input type="text" data-f="${escapeHtml(KhaytContentLanguages.fieldKey('description', lang))}"
           ${lang === 'ar' ? 'dir="rtl"' : ''}
           placeholder="${escapeHtml(t('pe.description_ph'))}"
           value="${escapeHtml(draft[KhaytContentLanguages.fieldKey('description', lang)] || '')}">`).join('')}

    <label>${escapeHtml(t('pe.default_margin'))} (${escapeHtml(t('common.percent'))})</label>
    <input type="number" min="0" data-f="defaultMargin" value="${draft.defaultMargin ?? 30}">

    <div id="prodPriceSummary" style="display:flex; align-items:center; justify-content:space-between; gap:12px; margin-top:12px; padding:10px 12px; background:var(--surface-2); border:1px solid var(--border-soft); border-radius:var(--radius);">
      <span style="font-size:12px; color:var(--text-muted);">${escapeHtml(t('pe.cost') || 'Cost')}: <b id="prodCostVal">—</b></span>
      <span style="font-size:13px;">${escapeHtml(t('pe.default_price') || 'Default price')}: <b id="prodPriceVal" style="color:var(--primary);">—</b>
        <span id="prodPriceWhy" style="font-size:11px;color:var(--text-muted);margin-inline-start:6px;"></span></span>
    </div>

    <!-- The calculated price is arithmetic; the price on the shelf is a decision.
         The calculated figure stays on screen either way, because it is what
         tells a shop whether its margin is working. -->
    <div style="display:flex; align-items:center; gap:8px; flex-wrap:wrap; margin-top:8px;">
      <label style="margin:0; font-size:12px; color:var(--text-muted);">${escapeHtml(t('pe.round_to') || 'Round to')}</label>
      <select id="prodRoundStep" style="width:auto; font-size:12.5px;">
        ${KhaytProductPrice.STEPS.map((st) => `<option value="${st}"${(+(draft.priceRound?.step) || 0) === st ? ' selected' : ''}>${st === 0 ? escapeHtml(t('pe.round_off') || 'No rounding') : st}</option>`).join('')}
      </select>
      <select id="prodRoundMode" style="width:auto; font-size:12.5px;">
        ${KhaytProductPrice.MODES.map((md) => `<option value="${md}"${(draft.priceRound?.mode || 'nearest') === md ? ' selected' : ''}>${escapeHtml(t('pe.round_' + md) || md)}</option>`).join('')}
      </select>
      <label style="margin:0; font-size:12px; color:var(--text-muted); margin-inline-start:8px;">${escapeHtml(t('pe.price_override') || 'Or set the price')}</label>
      <input type="number" min="0" step="0.01" inputmode="decimal" id="prodPriceOverride"
             placeholder="${escapeHtml(t('pe.price_override_ph') || 'auto')}"
             title="${escapeHtml(t('pe.price_override_hint') || 'A price you type here is used as-is and ignores the rounding above. Clear it to go back to the calculated price.')}"
             value="${draft.priceOverride != null ? escapeHtml(String(draft.priceOverride)) : ''}"
             style="width:96px; font-size:12.5px; text-align:right;">
    </div>

    <div style="display:flex; align-items:center; margin-top:14px; gap:10px;">
      <label style="margin:0; flex:1;">${escapeHtml(t('cat.tiers_section'))}</label>
      <button class="btn small" data-act="add-tier">${escapeHtml(t('cat.add_tier'))}</button>
    </div>
    <div id="tiersEditor" style="margin-top:6px;"></div>
    <p style="font-size:11.5px;color:var(--text-muted);margin:4px 0 0;">${escapeHtml(t('cat.tiers_hint'))}</p>

    <div style="display:flex; align-items:center; margin: 18px 0 8px; gap:10px;">
      <h3 class="card-head" style="margin:0; flex:1;"><span class="swatch"></span>${escapeHtml(t('pe.parts'))}</h3>
      <button class="btn small primary" data-act="add-part">${escapeHtml(t('pe.add_part'))}</button>
    </div>

    <div class="parts-editor" id="partsEditor">${partsHtml()}</div>

    <div style="display:flex; align-items:center; margin: 18px 0 8px; gap:10px;">
      <h3 class="card-head" style="margin:0; flex:1;"><span class="swatch"></span>${escapeHtml(t('bom.components') || 'Components (non-printed)')}</h3>
      <button class="btn small" data-act="add-component" ${(typeof consumables === 'undefined' || !consumables.length) ? 'disabled title="Add consumables first"' : ''}>${escapeHtml(t('bom.add_component') || 'Add component')}</button>
    </div>
    <p style="font-size:11.5px;color:var(--text-muted);margin:0 0 8px;">${escapeHtml(t('bom.components_hint') || 'Magnets, screws, inserts, packaging — drawn from your consumables when the order completes.')}</p>
    <div id="componentsEditor">${componentsHtml()}</div>

    <div style="display:flex; align-items:center; margin: 18px 0 8px; gap:10px;">
      <h3 class="card-head" style="margin:0; flex:1;"><span class="swatch"></span>${escapeHtml(t("pdoc.title") || "Documents")}</h3>
      <button class="btn small" data-act="add-pdoc">${escapeHtml(t("pdoc.add") || "Attach document")}</button>
    </div>
    <p style="font-size:11.5px;color:var(--text-muted);margin:0 0 8px;">${escapeHtml(t("pdoc.hint") || "Assembly instructions, safety sheets, drawings. Listed on the work order, and on the delivery note when marked to ship.")}</p>
    <div id="pdocEditor">${docsHtml()}</div>
  `;

  openFormModal({
    title: editing ? t('pe.edit_title') : t('pe.new_title'),
    saveLabel: t('pe.save'),
    bodyHtml,
    onMount(modal) {
      // Pricing tiers
      const tiersContainer = modal.querySelector('#tiersEditor');
      const tiersHtml = () => {
        if (!draft.priceTiers || draft.priceTiers.length === 0)
          return `<p style="font-size:12px;color:var(--text-muted);margin:0;">${escapeHtml(t('cat.no_tiers'))}</p>`;
        return draft.priceTiers.map((tier, i) => `
          <div class="tier-row" data-ti="${i}" style="display:flex;gap:8px;margin-bottom:6px;align-items:center;">
            <input type="text" class="tier-lbl" value="${escapeHtml(tier.label)}" placeholder="${escapeHtml(t('cat.tier_label'))}" style="flex:1;margin:0;">
            <input type="number" class="tier-mg" value="${tier.margin}" min="0" step="1" style="width:70px;margin:0;">
            <span style="font-size:12px;color:var(--text-muted);">%</span>
            <button class="btn danger small" data-act="rm-tier" data-ti="${i}" style="margin:0;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
          </div>`).join('');
      };
      const refreshTiers = () => { tiersContainer.innerHTML = tiersHtml(); };
      refreshTiers();

      modal.querySelector('[data-act="add-tier"]').addEventListener('click', () => {
        draft.priceTiers.push({ label: 'Wholesale', margin: 20 });
        refreshTiers();
      });
      tiersContainer.addEventListener('input', (e) => {
        const row = e.target.closest('[data-ti]');
        if (!row) return;
        const ti = +row.dataset.ti;
        if (e.target.classList.contains('tier-lbl')) draft.priceTiers[ti].label = e.target.value;
        if (e.target.classList.contains('tier-mg')) draft.priceTiers[ti].margin = num(e.target.value, 0);
      });
      tiersContainer.addEventListener('click', (e) => {
        const rm = e.target.closest('[data-act="rm-tier"]');
        if (rm) { draft.priceTiers.splice(+rm.dataset.ti, 1); refreshTiers(); }
      });

      const partsContainer = modal.querySelector('#partsEditor');

      // Live default-pricing summary — same cost math as the calculator, so adding a
      // product yields a ready default price (cost × margin) with no separate quoting step.
      function refreshPricing() {
        const r = productDefaultPricing(draft);
        const cEl = modal.querySelector('#prodCostVal');
        const pEl = modal.querySelector('#prodPriceVal');
        const wEl = modal.querySelector('#prodPriceWhy');
        if (cEl) cEl.textContent = fmtPrice(r.cost);
        if (pEl) pEl.textContent = fmtPrice(r.price);
        // Say WHICH number this is. A rounded price that does not admit it looks
        // like the arithmetic produced it, and then the two stop being tellable
        // apart — including the calculated figure, shown when it differs.
        if (wEl) {
          const why = KhaytProductPrice.describe(r, t);
          wEl.textContent = (r.priceSource === 'base' || Math.abs(r.price - r.basePrice) < 0.005)
            ? '' : `(${why} · ${fmtPrice(r.basePrice)})`;
        }
      }

      function refreshParts() {
        partsContainer.innerHTML = partsHtml();
        refreshPricing();
      }
      refreshPricing();

      // The rounding rule and the typed price both re-price immediately: a shop
      // choosing "round up to 5" wants to see the 45, not to save and find out.
      const roundStepEl = modal.querySelector('#prodRoundStep');
      const roundModeEl = modal.querySelector('#prodRoundMode');
      const overrideEl = modal.querySelector('#prodPriceOverride');
      const syncPriceRule = () => {
        const step = +(roundStepEl && roundStepEl.value) || 0;
        draft.priceRound = step > 0 ? { step, mode: (roundModeEl && roundModeEl.value) || 'nearest' } : null;
        const raw = overrideEl ? String(overrideEl.value).trim() : '';
        // Empty means "go back to the calculated price". 0 does not — a free
        // item is a decision, and null is the only way to say "no override".
        draft.priceOverride = raw === '' ? null : (Number.isFinite(+raw) && +raw >= 0 ? +raw : null);
        refreshPricing();
      };
      if (roundStepEl) roundStepEl.addEventListener('change', syncPriceRule);
      if (roundModeEl) roundModeEl.addEventListener('change', syncPriceRule);
      if (overrideEl) overrideEl.addEventListener('input', syncPriceRule);

      // Sync top-level inputs into draft
      modal.querySelectorAll('[data-f]').forEach(input => {
        input.addEventListener('input', () => {
          const f = input.dataset.f;
          if (f && Object.prototype.hasOwnProperty.call(draft, f)) {
            draft[f] = input.type === 'number' ? num(input.value, 0) : input.value;
          }
          if (f === 'defaultMargin') refreshPricing();
        });
      });

      // Part row inputs (delegated)
      partsContainer.addEventListener('input', (e) => {
        const input = e.target.closest('[data-f]');
        const row = e.target.closest('[data-pi]');
        if (!input || !row) return;
        const pi = +row.dataset.pi;
        const f = input.dataset.f;
        if (!draft.parts[pi]) return;
        draft.parts[pi][f] = input.type === 'number' ? num(input.value, 0) : input.value;
        refreshPricing();
      });

      // Part row actions
      partsContainer.addEventListener('click', (e) => {
        const rm = e.target.closest('[data-act="rm-part"]');
        if (rm) {
          draft.parts.splice(+rm.dataset.pi, 1);
          refreshParts();
        }
      });

      // Add a new part — defaults pulled from current calculator form
      modal.querySelector('[data-act="add-part"]').addEventListener('click', () => {
        draft.parts.push({
          name: '',
          filamentId: inventory[0]?.id || '',
          spoolCost:   num($('#spoolCost').value, 75),
          spoolWeight: num($('#spoolWeight').value, 1000),
          printWeight: 0,
          printTime: 0,
          wearRate:    num($('#wearRate').value, 0.75),
          powerDraw:   num($('#powerDraw').value, 150),
          elecRate:    num($('#elecRate').value, 0.18),
          prepTime: 0.1,
          postTime: 0.2,
          laborRate:   num($('#laborRate').value, 90),
          failureRate: num($('#failureRate').value, 10),
        });
        refreshParts();
      });

      // Product documents — attach / open / remove, and whether each ships.
      const pdocContainer = modal.querySelector('#pdocEditor');
      const refreshDocs = () => { if (pdocContainer) pdocContainer.innerHTML = docsHtml(); };
      modal.querySelector('[data-act="add-pdoc"]')?.addEventListener('click', async () => {
        try {
          const saved = await window.hubAPI?.pickAndSaveProductDoc?.(draft.id);
          if (!saved) return;                       // cancelled
          draft.docs.push({ ...saved, packWithOrder: true });
          refreshDocs();
        } catch (e) {
          console.error('attach product doc:', e);
          toast(t('pdoc.attach_failed') || 'Could not attach document', 'error');
        }
      });
      pdocContainer?.addEventListener('click', (ev) => {
        const open = ev.target.closest('[data-act="open-pdoc"]');
        const rm   = ev.target.closest('[data-act="rm-pdoc"]');
        if (open) {
          const d = draft.docs[+open.dataset.di];
          if (d) window.hubAPI?.openProductDoc?.(d.filename);
        }
        if (rm) {
          const i = +rm.dataset.di;
          const [gone] = draft.docs.splice(i, 1);
          // The file is only unlinked once the product is SAVED — see below.
          // Removing it here would delete a document the shop could still keep
          // by cancelling the dialog.
          if (gone?.filename) pendingDocDeletes.push(gone.filename);
          refreshDocs();
        }
      });
      pdocContainer?.addEventListener('change', (ev) => {
        const cb = ev.target.closest('.pdocPack');
        if (!cb) return;
        const d = draft.docs[+cb.dataset.di];
        if (d) d.packWithOrder = cb.checked;
      });

      // BOM components — add / edit / remove rows, refreshing the price summary.
      const componentsContainer = modal.querySelector('#componentsEditor');
      function refreshComponents() {
        componentsContainer.innerHTML = componentsHtml();
        refreshPricing();
      }
      modal.querySelector('[data-act="add-component"]')?.addEventListener('click', () => {
        const first = (typeof consumables !== 'undefined' && consumables[0]) ? consumables[0].id : '';
        draft.components.push({ id: uid('CMP'), consumableId: first, qtyPerUnit: 1 });
        refreshComponents();
      });
      componentsContainer.addEventListener('input', (e) => {
        const row = e.target.closest('[data-ci]');
        if (!row) return;
        const ci = +row.dataset.ci;
        if (!draft.components[ci]) return;
        if (e.target.classList.contains('bom-comp-consumable')) draft.components[ci].consumableId = e.target.value;
        if (e.target.classList.contains('bom-comp-qty')) draft.components[ci].qtyPerUnit = num(e.target.value, 0);
        refreshPricing();
      });
      componentsContainer.addEventListener('click', (e) => {
        const rm = e.target.closest('[data-act="rm-component"]');
        if (rm) { draft.components.splice(+rm.dataset.ci, 1); refreshComponents(); }
      });

      /**
       * Fill a part in from the print file it is printed from.
       *
       * Bound on the modal rather than on each row, because the parts list is
       * re-rendered whenever a part is added or removed and per-row listeners
       * would be lost — which is the ordinary way a button stops working with
       * nothing to show for it.
       */
      modal.addEventListener('click', (e) => {
        const btn = e.target.closest('.part-fill');
        if (!btn) return;
        const pi = +btn.dataset.pi;
        const part = draft.parts && draft.parts[pi];
        if (!part || !part.printFileId) return;
        const rec = (typeof printFiles !== 'undefined' ? printFiles : []).find((f) => f.id === part.printFileId);
        const patch = KhaytPartFromPrintFile.partPatch(rec, part.setupId);
        Object.assign(part, patch.fields);
        // Say what was filled AND what was not. A silent partial fill leaves
        // zeros that look like numbers somebody typed.
        toast(KhaytPartFromPrintFile.describe(patch, t), Object.keys(patch.from).length ? 'success' : 'info', 6000);
        refreshParts();
      });
      modal.addEventListener('change', (e) => {
        const sel = e.target.closest('.part-printfile');
        if (!sel) return;
        const part = draft.parts && draft.parts[+sel.dataset.pi];
        if (!part) return;
        part.printFileId = sel.value || null;
        // A new file means the old setup no longer applies.
        part.setupId = null;
        /* Fill the numbers NOW, not when someone finds the button.
         *
         * Linking a file used to record the link and stop there, leaving weight
         * and time at zero — which look exactly like numbers a shop typed. The
         * slicer already knows both, and the whole reason to link a file is that
         * it does.
         *
         * autoFill only writes fields that are still empty, so a weight the shop
         * put on a scale is never replaced by the slicer's estimate. Same rule
         * as the nozzle threshold: suggest, never rewrite. The fill button stays
         * for a deliberate re-fill, which DOES overwrite, because pressing it is
         * asking for exactly that.
         */
        if (part.printFileId) {
          const rec = (typeof printFiles !== 'undefined' ? printFiles : []).find((f) => f.id === part.printFileId);
          const patch = KhaytPartFromPrintFile.partPatch(rec, null);
          const { applied, kept } = KhaytPartFromPrintFile.autoFill(part, patch);
          const numbers = applied.filter((k) => k === 'printWeight' || k === 'printTime');
          if (numbers.length) {
            const keptNote = kept.length ? ' ' + (t('pe.fill_kept') || 'Your own values were kept.') : '';
            toast((t('pe.filled_from_file') || 'Weight and time filled in from the file.') + keptNote, 'success', 5000);
          } else if (patch && patch.missing && patch.missing.length && !kept.length) {
            // The file has no slicer data — say so, rather than leaving zeros
            // that look filled in.
            toast(KhaytPartFromPrintFile.describe(patch, t), 'info', 6000);
          }
        }
        refreshParts();
      });

      // ── Pictures ──────────────────────────────────────────────────────────
      //
      // Everything below re-renders the whole strip rather than patching one
      // node. There are at most a handful of pictures and the alternative is a
      // second place that has to know the markup — which is how the old single
      // slot drifted out of step with `draft` in the first place.
      const imagesBlock = modal.querySelector('#productImagesBlock');

      const addFiles = async (files) => {
        for (const file of [...(files || [])]) {
          if (!file.type.startsWith('image/')) continue;
          if (file.size > 8 * 1024 * 1024) { toast(t('pe.image_too_big'), 'error'); continue; }
          try {
            stagedImages.push({
              id: KhaytProductImages.imageId(draft.id, stagedImages.length + Date.now() % 1000),
              path: '',
              thumbnail: await resizeImage(file, 240, 0.85),
              full: await resizeImage(file, 1600, 0.88),
              // Unlabelled arrives as a render: it is the claim that cannot
              // mislead a customer into expecting a photo of a real part.
              kind: KhaytProductImages.DEFAULT_KIND,
              caption: '',
            });
          } catch (err) { console.error(err); toast(t('inv.image_error'), 'error'); }
        }
        redrawImages();
      };

      function redrawImages() {
        imagesBlock.innerHTML = imagesHtml();
        wireImages();
      }

      function wireImages() {
        const photoInput = modal.querySelector('#productPhotoInput');
        const photoDrop = modal.querySelector('.photo-drop');
        modal.querySelectorAll('[data-act="pick-photo"]').forEach((el) =>
          el.addEventListener('click', () => photoInput.click()));
        photoInput.addEventListener('change', async (e) => {
          // COPY THE LIST BEFORE CLEARING THE INPUT.
          //
          // `e.target.files` is a LIVE FileList, not a snapshot: setting
          // `value = ''` empties the very collection this was about to read, so
          // addFiles() got nothing and picking a photo silently did nothing at
          // all. The single-slot code this replaced took `files[0]` first — a
          // real File reference — so clearing after was safe there and is not
          // safe here. Reported as "the catalogue won't accept images".
          const files = [...e.target.files];
          e.target.value = '';
          await addFiles(files);
        });
        ['dragover', 'dragenter'].forEach((ev) => photoDrop.addEventListener(ev, (e) => {
          e.preventDefault(); photoDrop.classList.add('dragover');
        }));
        ['dragleave', 'drop'].forEach((ev) => photoDrop.addEventListener(ev, () => {
          photoDrop.classList.remove('dragover');
        }));
        photoDrop.addEventListener('drop', async (e) => {
          e.preventDefault();
          await addFiles(e.dataTransfer.files);
        });

        modal.querySelectorAll('.pi-kind').forEach((sel) => sel.addEventListener('change', () => {
          const img = stagedImages.find((x) => x.id === sel.dataset.id);
          if (img && KhaytProductImages.KIND_KEYS.includes(sel.value)) img.kind = sel.value;
        }));
        modal.querySelectorAll('.pi-primary').forEach((b) => b.addEventListener('click', () => {
          const i = stagedImages.findIndex((x) => x.id === b.dataset.id);
          if (i > 0) stagedImages.unshift(stagedImages.splice(i, 1)[0]);
          redrawImages();
        }));
        modal.querySelectorAll('.pi-remove').forEach((b) => b.addEventListener('click', () => {
          const i = stagedImages.findIndex((x) => x.id === b.dataset.id);
          if (i === -1) return;
          const [gone] = stagedImages.splice(i, 1);
          // Queued, NOT unlinked now: cancelling the dialog must leave the file
          // where it was. The same rule the document list already follows.
          if (gone.path) removedImages.push(gone.path);
          redrawImages();
        }));
      }
      wireImages();
    },

    async onSave(modal) {
      // Validate
      /* ANY of the shop's languages, not two of the nine.
       *
       * This checked nameEn and nameAr only, so a shop writing German filled in
       * the only name field it has and was told to "give the product a name
       * first" — the editor was unusable for seven of the nine languages the
       * app offers. read() looks through the shop's own languages and then
       * anything filled in at all. */
      if (!KhaytContentLanguages.read(draft, 'name', null, typeof settings !== 'undefined' ? settings : null).trim()) {
        toast(t('pe.need_name'), 'error');
        return false;
      }
      if (!draft.parts || draft.parts.length === 0) {
        toast(t('pe.need_part'), 'error');
        return false;
      }

      // ── Write the pictures ────────────────────────────────────────────────
      //
      // Only the ones added in this session have a `full` to write; the rest
      // keep the path they already had. A failed write drops that ONE picture
      // rather than the save — losing a whole product edit because one image
      // could not be written would be a much worse trade.
      if (window.hubAPI?.saveProductImage) {
        for (const img of stagedImages) {
          if (!img.full) continue;
          try {
            // The image id, so several photos on one product do not all write
            // to the same file — see the handler in main.js.
            img.path = await window.hubAPI.saveProductImage(draft.id, img.full, img.id);
          } catch (err) {
            console.error('save image failed', err);
            toast(t('pe.image_save_failed') || 'One picture could not be saved', 'warning');
          }
        }
      }
      draft.images = stagedImages
        .filter((img) => img.path || img.thumbnail)
        .map(({ id, path, thumbnail, kind, caption }) => ({ id, path, thumbnail, kind, caption }));
      // Keeps imagePath/thumbnail pointing at images[0] for everything that
      // still reads them — the storefront, the portal, label printing.
      KhaytProductImages.apply(draft);

      // Only now unlink what the shop removed. Cancelling must leave them.
      if (window.hubAPI?.deleteProductImage) {
        for (const path of removedImages) {
          window.hubAPI.deleteProductImage(path).catch(() => {});
        }
      }

      // Compute default pricing from parts + margin (same math as the calculator) so
      // the product carries a ready price without a separate quoting step.
      const pricing = productDefaultPricing(draft);
      draft.baseCost = pricing.cost;
      draft.basePrice = pricing.basePrice;
      // What the shop actually charges, after its own rounding or override.
      draft.price = pricing.price;

      // Persist
      /* Through lib/organise.js, so a name matching one already in use adopts
       * its spelling — across BOTH screens. Typed straight onto the record,
       * "saudi kings" on the catalogue and "Saudi Kings" in the library are two
       * collections, and the shop has to know which half is where. */
      Object.assign(draft, organiseAssign(draft, { group: draft.group, category: draft.category }));

      const idx = products.findIndex(p => p.id === draft.id);
      if (idx >= 0) products[idx] = draft;
      else products.push(draft);

      // Only now unlink documents the shop removed: cancelling the dialog must
      // leave them untouched on disk.
      for (const fn of pendingDocDeletes) {
        try { window.hubAPI?.deleteProductDoc?.(fn); } catch (e) { console.error('delete product doc:', e); }
      }

      saveAll();
      renderCatalog();
      toast(t('pe.saved'), 'success');
      return true;
    }
  });
}

/* ----- Image resize util (returns dataURL) ----- */
function resizeImage(file, maxDim, quality = 0.9) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = (e) => {
      const img = new Image();
      img.onload = () => {
        const ratio = Math.min(1, maxDim / Math.max(img.width, img.height));
        const w = Math.round(img.width * ratio);
        const h = Math.round(img.height * ratio);
        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = '#ffffff'; // flatten transparency to white for JPEG
        ctx.fillRect(0, 0, w, h);
        ctx.drawImage(img, 0, 0, w, h);
        resolve(canvas.toDataURL('image/jpeg', quality));
      };
      img.onerror = reject;
      img.src = e.target.result;
    };
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

/* ============================================================
   Feature 4 (new batch): Material depletion forecast
   ============================================================ */
function computeMaterialForecast() {
  const results = [];
  const now = new Date();
  const thirtyDaysAgo = new Date(now); thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
  const thirtyAgoStr = localDateStr(thirtyDaysAgo);

  for (const item of inventory) {
    // Sum weight queued (non-completed, non-quote orders using this material)
    let queued = 0;
    for (const o of printLog) {
      if (o.status === 'completed' || o.status === 'quote') continue;
      for (const p of (o.parts || [])) {
        queued += partGramsForSpool(p, item.id); // colour-aware: splits multicolour parts per spool
      }
      if (!o.parts || o.parts.length === 0) {
        if (o.material && o.material === item.material) queued += (+o.weight || 0);
      }
    }
    const available = (item.weight || 0) - queued;

    // Daily usage from last 30 days of completed orders
    const recentCompleted = printLog.filter(o => o.status === 'completed' && (o.date || '') >= thirtyAgoStr);
    let recentGrams = 0;
    for (const o of recentCompleted) {
      for (const p of (o.parts || [])) {
        recentGrams += partGramsForSpool(p, item.id); // colour-aware per-spool split
      }
    }
    const dailyUsage = recentGrams / 30;
    const daysRemaining = (dailyUsage > 0 && available > 0) ? Math.floor(available / dailyUsage) : null;

    if (available < 0 || (daysRemaining !== null && daysRemaining < 30)) {
      results.push({
        material: item.material,
        available: Math.round(available),
        daysRemaining,
        urgent: available < 0 || (daysRemaining !== null && daysRemaining < 7),
      });
    }
  }
  return results.sort((a, b) => (a.daysRemaining ?? -999) - (b.daysRemaining ?? -999));
}

function renderProductTierChips(product) {
  const strip = $('#priceTiersStrip');
  if (!strip) return;
  if (!product?.priceTiers || product.priceTiers.length === 0) {
    strip.style.display = 'none';
    return;
  }
  strip.style.display = 'flex';
  strip.innerHTML = `
    <span style="font-size:12px;color:var(--text-muted);align-self:center;">${escapeHtml(t('cat.pick_tier'))}</span>
    ${product.priceTiers.map(tier => `
      <button class="tier-chip" data-margin="${+tier.margin}" data-act="pick-tier">
        ${escapeHtml(tier.label)} <span class="tier-margin">${tier.margin}%</span>
      </button>`).join('')}`;
  strip.querySelectorAll('[data-act="pick-tier"]').forEach(btn => {
    btn.addEventListener('click', () => {
      $('#margin').value = btn.dataset.margin;
      updateGrandTotal();
      strip.querySelectorAll('.tier-chip').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
    });
  });
}

/* ============================================================
   Reorder reminder (inventory low-stock)
   ============================================================ */
async function batchGenPOs() {
  // Scope reorder generation to the active location (+ unassigned stock).
  const activeLoc = (typeof activeLocation !== 'undefined') ? activeLocation : null;
  const lowStockItems = filterInventoryByLocation(inventory, activeLoc).filter(isLowStock);
  if (lowStockItems.length === 0) {
    toast(t('po.none_needed'), 'info');
    return;
  }
  // Group by supplier
  const bySupplier = {};
  for (const item of lowStockItems) {
    const key = item.supplier || '—';
    if (!bySupplier[key]) bySupplier[key] = [];
    bySupplier[key].push(item);
  }
  const rowsHtml = Object.entries(bySupplier).map(([sup, items]) =>
    items.map(item => `
      <tr>
        <td>${escapeHtml(sup)}</td>
        <td>${escapeHtml(item.material)}</td>
        <td>${Math.round(item.weight || 0)}g</td>
        <td>${Math.round(item.reorderQty || 1000)}g</td>
      </tr>`).join('')
  ).join('');
  const confirmed = await new Promise(resolve => {
    openFormModal({
      title: t('po.batch_confirm', { n: lowStockItems.length }),
      saveLabel: t('common.confirm'),
      sizeLg: false,
      bodyHtml: `
        <div style="overflow-x:auto;max-height:280px;overflow-y:auto;">
          <table style="width:100%;font-size:12px;border-collapse:collapse;">
            <thead><tr style="color:var(--text-muted);">
              <th style="text-align:left;padding:4px 6px;">${escapeHtml(t('po.supplier'))}</th>
              <th style="text-align:left;padding:4px 6px;">${escapeHtml(t('po.item'))}</th>
              <th style="text-align:right;padding:4px 6px;">${escapeHtml(t('po.current'))}</th>
              <th style="text-align:right;padding:4px 6px;">${escapeHtml(t('po.order_qty'))}</th>
            </tr></thead>
            <tbody>${rowsHtml}</tbody>
          </table>
        </div>`,
      async onSave() { resolve(true); return true; }
    });
    // If modal is closed without save, resolve false
    const observer = new MutationObserver(() => {
      if (!document.querySelector('#modalMount .modal')) { observer.disconnect(); resolve(false); }
    });
    observer.observe($('#modalMount'), { childList: true });
  });
  if (!confirmed) return;
  for (const item of lowStockItems) {
    createPurchaseOrder(item);
  }
  saveAll();
  renderPurchaseOrders();
  toast(t('po.batch_done', { n: lowStockItems.length }), 'success');
}

function createPurchaseOrder(item, opts) {
  // opts: { supplierId, supplierName, qty, unitPrice, estimatedDelivery, notes }
  const resolvedSupplierId = (opts && opts.supplierId) || item.supplierId || null;
  const resolvedSupplierName = (opts && opts.supplierName) || (resolvedSupplierId ? (suppliers.find(s => s.id === resolvedSupplierId)?.name || '') : '');
  // A consumable is counted in the shop's own unit, not in grams, and is named
  // rather than described by material. `kind` is absent on every PO written
  // before consumables could be ordered, so absent MUST read as filament — the
  // receive path restocks a different field depending on this answer.
  const isConsumable = !!(opts && opts.kind === 'consumable');
  const po = {
    id: uid('PO'),
    ...(isConsumable ? { kind: 'consumable', unit: (item.unit || '').trim() } : {}),
    itemId: item.id,
    itemName: isConsumable ? (item.name || '') : item.material,
    supplierId: resolvedSupplierId,
    supplierName: resolvedSupplierName,
    // 1000 is a spool; it is not a sane default for a box of screws.
    qty: (opts && opts.qty) ? +opts.qty : (item.reorderQty || (isConsumable ? 1 : 1000)),
    unitPrice: (opts && opts.unitPrice) ? +opts.unitPrice : undefined,
    estimatedDelivery: (opts && opts.estimatedDelivery) || null,
    status: (opts && opts.status) || 'ordered',
    orderedAt: localDateStr(),
    receivedAt: null,
    notes: (opts && opts.notes) || '',
  };
  purchaseOrders.unshift(po);
  if (opts && opts.silent) return po; // caller batches save/render/toast
  saveAll();
  renderPurchaseOrders();
  toast(t('po.created_toast'), 'success');
  return po;
}

/**
 * Warn about purchase orders drafted before the per-gram unit-price fix.
 *
 * resolveReorderPrice() used to return a whole-spool cost where a per-gram rate
 * was expected, and PO qty is in grams — so affected orders ask for roughly
 * 1000x the real amount. The code is fixed; stores written earlier are not.
 *
 * This only FLAGS. A purchase order may already have been sent to a supplier,
 * so rewriting an amount without the owner looking would be worse than the bug
 * it corrects. Each row shows both figures and corrects only on click.
 */
function poSuspectBannerHtml() {
  const A = window.KhaytPoAudit;
  if (!A) return '';
  const suspects = A.findSuspectPurchaseOrders(purchaseOrders, inventory);
  if (!suspects.length) return '';
  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';
  const money = (n) => `${(typeof fmtMoney === 'function' ? fmtMoney(n) : Math.round(n))}${cur ? ' ' + cur : ''}`;
  const rows = suspects.map((e) => `
    <div class="po-suspect-row">
      <span class="po-suspect-name">${escapeHtml(e.po.itemName || e.po.id)}</span>
      <span class="po-suspect-was">${escapeHtml(money(e.currentTotal))}</span>
      <span class="po-suspect-arrow" aria-hidden="true">→</span>
      <span class="po-suspect-now">${escapeHtml(e.suggestedTotal == null ? '—' : money(e.suggestedTotal))}</span>
      ${e.suggested == null
        ? `<span class="po-suspect-manual">${escapeHtml(t('po.fix_manual') || 'set the price by hand')}</span>`
        : `<button type="button" class="btn small" data-act="po-fix-price" data-id="${escapeHtml(e.po.id)}">${escapeHtml(t('po.fix_btn') || 'Correct')}</button>`}
    </div>`).join('');
  return `
    <div class="po-suspect">
      <p class="po-suspect-head">${escapeHtml(
        (t('po.suspect_head') || 'Some purchase orders were priced per spool instead of per gram, so the amounts are about 1000x too high.')
        + ' ' + (t('po.suspect_sub') || 'Nothing has been changed — review each one before correcting.'))}</p>
      ${rows}
    </div>`;
}

function renderPurchaseOrders() {
  const sec = $('#poSection');
  if (!sec) return;
  const relevant = purchaseOrders.filter(po => {
    if (poStatusFilter && po.status !== poStatusFilter) return false;
    if (poSearchTerm) {
      const term = poSearchTerm.toLowerCase();
      if (!(po.itemName || po.id || '').toLowerCase().includes(term) &&
          !(po.supplierName || '').toLowerCase().includes(term) &&
          !(po.notes || '').toLowerCase().includes(term)) return false;
    }
    return true;
  });

  // Reset display limit when filters change
  const poFilterHash = [poStatusFilter, poSearchTerm].join('\x00');
  if (poFilterHash !== _lastPoFilterHash) {
    poDisplayLimit = 50;
    _lastPoFilterHash = poFilterHash;
  }

  // AP Aging: unpaid/pending POs grouped by age
  const today = Date.now();
  const unpaidPOs = relevant.filter(po => po.status !== 'received' || (po.supplierInvoice && !po.invoicePaid));
  const aging = { current: 0, d30: 0, d60: 0 };
  for (const po of unpaidPOs) {
    const orderedMs = po.orderedAt ? new Date(po.orderedAt + 'T00:00:00').getTime() : today;
    const agedays = Math.floor((today - orderedMs) / 86400000);
    if (agedays < 30) aging.current++;
    else if (agedays < 60) aging.d30++;
    else aging.d60++;
  }
  const agingHtml = unpaidPOs.length > 0 ? `
    <div class="ap-aging-bar" style="display:flex;gap:12px;flex-wrap:wrap;padding:8px 12px;background:var(--surface-2);border-radius:var(--radius);margin-bottom:12px;font-size:12.5px;align-items:center;">
      <span style="font-weight:600;color:var(--text-muted);">${escapeHtml(t('po.ap_aging'))}</span>
      <span style="color:var(--success);">● ${aging.current} ${escapeHtml(t('po.aging_lt30'))}</span>
      <span style="color:var(--warning);">● ${aging.d30} ${escapeHtml(t('po.aging_30_60'))}</span>
      <span style="color:var(--danger);">● ${aging.d60} ${escapeHtml(t('po.aging_60plus'))}</span>
      <span style="margin-inline-start:auto;color:var(--text-muted);">${unpaidPOs.length} ${escapeHtml(t('po.aging_unpaid'))}</span>
    </div>` : '';

  sec.innerHTML = `
    ${poSuspectBannerHtml()}
    <div style="display:flex; align-items:center; gap:12px; margin-bottom:12px; flex-wrap:wrap;">
      <h3 class="card-head" style="margin:0; flex:1;"><span class="swatch"></span><span>${escapeHtml(t('po.title'))}</span></h3>
      <input type="search" id="poSearch" class="search-input" placeholder="${escapeHtml(t('po.search_ph'))}" value="${escapeHtml(poSearchTerm)}" style="max-width:200px;">
      <select id="poStatusSel" style="background:var(--bg-elev);color:var(--text);border:1px solid var(--border);border-radius:6px;padding:4px 8px;font-size:12px;">
        <option value=""${poStatusFilter===''?' selected':''}>${escapeHtml(t('common.all'))}</option>
        <option value="draft"${poStatusFilter==='draft'?' selected':''}>${escapeHtml(t('po.status.draft'))}</option>
        <option value="ordered"${poStatusFilter==='ordered'?' selected':''}>${escapeHtml(t('po.status.ordered'))}</option>
        <option value="partial"${poStatusFilter==='partial'?' selected':''}>${escapeHtml(t('po.partial'))}</option>
        <option value="received"${poStatusFilter==='received'?' selected':''}>${escapeHtml(t('po.status.received'))}</option>
      </select>
      <button class="btn small pro-only" data-act="batch-gen-pos">📦 ${escapeHtml(t('po.batch_gen'))}</button>
    </div>
    ${agingHtml}
    ${relevant.length === 0
      ? `<p style="color:var(--text-muted); font-size:13px;">${escapeHtml(t('po.empty'))}</p>`
      : (() => {
          const page = relevant.slice(0, poDisplayLimit);
          const loadMoreRow = relevant.length > poDisplayLimit
            ? `<tr><td colspan="5" style="text-align:center;padding:12px;">
                <button class="btn small ghost" data-act="load-more-pos">
                  ${escapeHtml(t('log.load_more') || 'Load more')} (${relevant.length - poDisplayLimit} ${escapeHtml(t('log.remaining') || 'remaining')})
                </button>
              </td></tr>` : '';
          return `<div class="table-wrap"><table class="po-table">
          <thead><tr>
            <th>${escapeHtml(t('po.item'))}</th>
            <th>${escapeHtml(t('po.supplier'))}</th>
            <th>${escapeHtml(t('po.ordered_at'))}</th>
            <th>${escapeHtml(t('po.status'))}</th>
            <th></th>
          </tr></thead>
          <tbody>
          ${page.map(po => {
            const receivedSoFar = po.receivedSoFar || 0;
            // `qty` is what createPurchaseOrder writes; `weightOrdered` is written
            // by nothing, so this bar was 0/0 on every order and never appeared.
            // The unit follows the order's kind for the same reason the receive
            // dialog's does — a part-received box of screws is not "4g / 8g".
            const ordered = +po.qty || 0;
            const poUnit = po.kind === 'consumable'
              ? ((po.unit || '').trim() || (t('cons.unit') || 'units'))
              : 'g';
            const progressPct = ordered > 0 ? Math.min(100, (receivedSoFar / ordered) * 100) : 0;
            const isPartial = po.status === 'partial';
            const progressHtml = isPartial && ordered > 0 ? `
              <div style="margin-top:4px; font-size:11px; color:var(--text-muted);">${escapeHtml(t('po.received_so_far'))}: ${receivedSoFar}${escapeHtml(poUnit)} / ${ordered}${escapeHtml(poUnit)}</div>
              <div class="po-progress-bar"><div style="width:${progressPct.toFixed(1)}%;background:var(--primary);height:100%;border-radius:2px;"></div></div>` : '';
            return `
            <tr>
              <td><strong>${escapeHtml(po.itemName || po.id)}</strong>${progressHtml}</td>
              <td style="color:var(--text-dim);">${escapeHtml(po.supplierName || '—')}</td>
              <td style="font-size:12px; color:var(--text-muted);">${escapeHtml(po.orderedAt || '')}</td>
              <td>
                <span class="po-badge ${escapeHtml(po.status)}">${isPartial ? escapeHtml(t('po.partial')) : escapeHtml(t('po.status.' + po.status))}</span>
                ${po.supplierInvoice ? (po.invoiceDiscrepancy
                  ? `<span class="ap-mismatch-badge" title="${escapeHtml(t('po.ap_mismatch'))}">⚠ ${escapeHtml(t('po.ap_mismatch'))}</span>`
                  : `<span class="ap-matched-badge" title="${escapeHtml(t('po.ap_matched'))}">✔ ${escapeHtml(t('po.ap_matched'))}</span>`) : ''}
              </td>
              <td style="white-space:nowrap;">
                ${(po.status === 'ordered' || isPartial) ? `<button class="btn small success" data-act="po-receive" data-id="${po.id}">${escapeHtml(isPartial ? t('po.receive_more') : t('po.receive'))}</button>` : `<span style="font-size:11px; color:var(--text-muted);">${escapeHtml(po.receivedAt || '')}</span>`}
                ${isPartial ? `<button class="btn small ghost" data-act="po-close" data-id="${po.id}" style="margin-inline-start:4px;">${escapeHtml(t('po.close_po'))}</button>` : ''}
                ${(po.status === 'received' || isPartial) ? `<button class="btn small ghost pro-only" data-act="po-record-invoice" data-id="${po.id}" style="margin-inline-start:4px;" title="${escapeHtml(t('po.ap_record'))}">🧾 ${escapeHtml(t('po.ap_record'))}</button>` : ''}
                <button class="btn danger small" data-act="po-del" data-id="${po.id}" style="margin-inline-start:4px;" aria-label="${escapeHtml(t('common.delete'))}" title="${escapeHtml(t('common.delete'))}">×</button>
              </td>
            </tr>`;
          }).join('')}
          ${loadMoreRow}
          </tbody></table></div>`;
        })()
    }`;
  // Attach event listeners to the dynamically-rendered search/filter controls
  const poSearchEl = sec.querySelector('#poSearch');
  if (poSearchEl) poSearchEl.addEventListener('input', (e) => { poSearchTerm = e.target.value; renderPurchaseOrders(); });
  const poStatusSelEl = sec.querySelector('#poStatusSel');
  if (poStatusSelEl) poStatusSelEl.addEventListener('change', (e) => { poStatusFilter = e.target.value; renderPurchaseOrders(); });
}

function openReorderModal(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const orderQty = item.reorderQty || 1000;
  const defaultMsg = t('inv.reorder_msg', { material: item.material, weight: Math.round(item.weight) })
    .replace(/\.$/, '') + `. Please send ${orderQty}g. Thank you!`;
  const supplierOptions = suppliers.map(s =>
    `<option value="${escapeHtml(s.id)}"${s.id === item.supplierId ? ' selected' : ''}>${escapeHtml(s.name)}</option>`
  ).join('');
  const overlay = appendStackedModal(`
      <div class="modal modal-form modal-lg" role="dialog" aria-modal="true" aria-labelledby="reorderModalTitle">
        <div class="modal-header">
          <h3 id="reorderModalTitle">${escapeHtml(t('inv.draft_po_title') || 'Draft Purchase Order')}</h3>
          <button class="btn ghost small" id="reorderModalClose" aria-label="Close" title="Close">×</button>
        </div>
        <div class="modal-body">
          <div class="inline-pair">
            <div>
              <label>${escapeHtml(t('po.supplier') || 'Supplier')}</label>
              <select id="reorderSupplier" style="width:100%;">
                <option value="">— ${escapeHtml(t('po.no_supplier') || 'No supplier')} —</option>
                ${supplierOptions}
              </select>
            </div>
            <div>
              <label>${escapeHtml(t('po.qty') || 'Quantity')} (g)</label>
              <input type="number" id="reorderQtyInput" value="${orderQty}" min="1">
            </div>
          </div>
          <div class="inline-pair" style="margin-top:10px;">
            <div>
              <label>${escapeHtml(t('po.unit_price') || 'Unit price')} (${escapeHtml(t('inv.per_g') || 'per g, optional')})</label>
              <input type="number" id="reorderUnitPrice" value="" min="0" step="0.01" placeholder="0.00">
            </div>
            <div>
              <label>${escapeHtml(t('po.est_delivery') || 'Estimated delivery')}</label>
              <input type="date" id="reorderDeliveryDate">
            </div>
          </div>
          <label style="margin-top:10px;">${escapeHtml(t('common.notes') || 'Notes')}</label>
          <textarea id="reorderNotes" rows="2" style="resize:vertical;"></textarea>
          <hr style="margin:14px 0;border:none;border-top:1px solid var(--border);">
          <label>${escapeHtml(t('set.supplier_phone'))}</label>
          <input type="tel" id="reorderPhone" value="${escapeHtml((suppliers.find(s => s.id === item.supplierId)?.phone) || settings.supplierPhone || '')}" data-i18n-placeholder="set.supplier_ph">
          <label style="margin-top:10px;">${escapeHtml(t('wa.tpl_body'))}</label>
          <textarea id="reorderMsg" rows="3" style="resize:vertical;">${escapeHtml(defaultMsg)}</textarea>
        </div>
        <div class="modal-footer" style="display:flex;gap:8px;justify-content:flex-end;">
          <button class="btn ghost" id="reorderModalCancel">${escapeHtml(t('common.cancel'))}</button>
          <button class="btn" id="reorderDraftOnly">${escapeHtml(t('inv.draft_po_only') || 'Draft PO Only')}</button>
          <button class="btn primary" id="reorderDraftAndWa">${escapeHtml(t('inv.draft_po_whatsapp') || 'Draft PO + WhatsApp')}</button>
        </div>
      </div>`, { zIndex: 10040 });
  if (!overlay) return;

  const close = () => {
    document.removeEventListener('keydown', escH);
    const idx = _escHandlerStack.indexOf(escH);
    if (idx !== -1) _escHandlerStack.splice(idx, 1);
    overlay.remove();
  };
  const escH = (e) => { if (e.key === 'Escape') close(); };
  _escHandlerStack.push(escH);
  document.addEventListener('keydown', escH);
  overlay.querySelector('#reorderModalClose').addEventListener('click', close);
  overlay.querySelector('#reorderModalCancel').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  // Update phone when supplier changes
  overlay.querySelector('#reorderSupplier').addEventListener('change', function() {
    const sup = suppliers.find(s => s.id === this.value);
    if (sup?.phone) overlay.querySelector('#reorderPhone').value = sup.phone;
  });

  const collectOpts = () => {
    const modal = overlay.querySelector('.modal');
    const supId = modal.querySelector('#reorderSupplier').value;
    const sup = suppliers.find(s => s.id === supId);
    return {
      supplierId:        supId || null,
      supplierName:      sup?.name || '',
      qty:               +modal.querySelector('#reorderQtyInput').value || orderQty,
      unitPrice:         +modal.querySelector('#reorderUnitPrice').value || undefined,
      estimatedDelivery: modal.querySelector('#reorderDeliveryDate').value || null,
      notes:             modal.querySelector('#reorderNotes').value.trim(),
    };
  };

  overlay.querySelector('#reorderDraftOnly').addEventListener('click', () => {
    const opts = collectOpts();
    const phone = overlay.querySelector('#reorderPhone').value.trim();
    if (phone && phone !== settings.supplierPhone) {
      settings.supplierPhone = phone;
      saveAll();
      const el = $('#set_supplierPhone');
      if (el) el.value = phone;
    }
    createPurchaseOrder(item, opts);
    close();
  });

  overlay.querySelector('#reorderDraftAndWa').addEventListener('click', async () => {
    const opts = collectOpts();
    const phone = overlay.querySelector('#reorderPhone').value.trim();
    const msg   = overlay.querySelector('#reorderMsg').value;
    if (phone && phone !== settings.supplierPhone) {
      settings.supplierPhone = phone;
      saveAll();
      const el = $('#set_supplierPhone');
      if (el) el.value = phone;
    }
    createPurchaseOrder(item, opts);
    if (window.hubAPI?.shareWhatsApp) {
      await window.hubAPI.shareWhatsApp({ phone, message: msg, pdfPath: null });
    }
    close();
  });
}

// Consolidated "what to buy" list — every filament at/under its reorder point,
// grouped by supplier, with how much you have and how much to buy. Purely a
// planning aid (no purchasing), so it stays commerce-free. Copyable + printable.
function openShoppingList() {
  const low = inventory.filter(isLowStock);
  if (!low.length) {
    toast(t('shop.none') || 'Nothing to buy — every filament is above its reorder point.', 'success');
    return;
  }
  const groups = {};
  low.forEach((item) => {
    let supName = '';
    try {
      const price = (typeof resolveReorderPrice === 'function') ? resolveReorderPrice(item) : null;
      supName = (price && price.supplierName) || '';
    } catch (e) { /* ignore */ }
    if (!supName && item.supplierId && typeof suppliers !== 'undefined') {
      const s = suppliers.find((x) => x.id === item.supplierId);
      supName = (s && s.name) || '';
    }
    if (!supName) supName = t('shop.no_supplier') || 'No supplier set';
    (groups[supName] = groups[supName] || []).push({
      name: item.material || 'Filament',
      have: Math.round(+item.weight || 0),
      buy: Math.round(+item.reorderQty || 1000),
      color: item.color || '#888',
    });
  });

  const supNames = Object.keys(groups).sort();
  // Language-neutral item line: "Name   120 g → 1000 g"
  const textLines = [(t('shop.title') || 'Shopping list') + ' — ' + (shopName() || 'Bed Ready'), ''];
  let html = '';
  supNames.forEach((sup) => {
    textLines.push(sup);
    html += `<div class="shop-group"><div class="shop-sup">${escapeHtml(sup)}</div>`;
    groups[sup].forEach((r) => {
      textLines.push(`  • ${r.name}   ${r.have} g → ${r.buy} g`);
      html += `<div class="shop-row"><span class="shop-dot" style="background:${safeCssColor(r.color)}"></span>`
        + `<span class="shop-name">${escapeHtml(r.name)}</span>`
        + `<span class="shop-amt">${r.have} g <span class="shop-arrow">→</span> ${r.buy} g</span></div>`;
    });
    textLines.push('');
    html += `</div>`;
  });
  const text = textLines.join('\n');

  openFormModal({
    title: '🛒 ' + (t('shop.title') || 'Shopping list'),
    noSave: true,
    bodyHtml: `<div class="shop-list">${html}</div>
      <div style="display:flex;gap:8px;margin-top:14px;">
        <button type="button" class="btn primary" id="shopCopyBtn">📋 ${escapeHtml(t('shop.copy') || 'Copy list')}</button>
        <button type="button" class="btn ghost" id="shopPrintBtn">🖨 ${escapeHtml(t('common.print') || 'Print')}</button>
      </div>`,
    onMount(modal) {
      modal.querySelector('#shopCopyBtn')?.addEventListener('click', () => { copyAndToast(text); });
      modal.querySelector('#shopPrintBtn')?.addEventListener('click', () => {
        if (typeof window.print === 'function') window.print();
      });
    },
  });
}

function exportInventoryCsv() {

  const headers = [
    'ID', 'Material', 'Color', 'Brand',
    `Weight (g)`, `Remaining (g)`, `Cost/g (${currencySymbol()})`,
    'Location', 'Low Stock'
  ];

  const lines = [
    headers.map(csvEsc).join(','),
    ...inventory.map(spool => [
      spool.id,
      spool.material || '',
      spool.colorName || spool.color || '',
      spool.brand || '',
      +spool.weight  || 0,
      +spool.remaining !== undefined ? +spool.remaining : +spool.weight || 0,
      spool.costPerGram != null ? (+spool.costPerGram).toFixed(4) : '',
      spool.location || '',
      isLowStock(spool) ? 'Yes' : 'No'   // use the shared check (<=, per-item reorderPoint)
    ].map(csvEsc).join(','))
  ];

  downloadBlob(
    new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8;' }),
    `inventory-${localDateStr()}.csv`
  );
}

function recordSupplierInvoice(poId) {
  const po = purchaseOrders.find(p => p.id === poId);
  if (!po) return;
  openFormModal({
    title: t('po.ap_record'),
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('po.sup_inv_num'))}</label>
      <input type="text" id="poSupInvNum" placeholder="${escapeHtml(t('po.sup_inv_num'))}" value="${escapeHtml(po.supplierInvoice?.number || '')}">
      <label style="margin-top:12px;">${escapeHtml(t('po.sup_inv_amount'))} (${currencySymbol()})</label>
      <input type="number" id="poSupInvAmount" min="0" step="0.01" value="${po.supplierInvoice?.amount || ''}">
      <label style="margin-top:12px;">${escapeHtml(t('po.sup_inv_date'))}</label>
      <input type="date" id="poSupInvDate" value="${escapeHtml(po.supplierInvoice?.date || localDateStr())}">`,
    onSave(modal) {
      const number = modal.querySelector('#poSupInvNum').value.trim();
      const amount = parseFloat(modal.querySelector('#poSupInvAmount').value) || 0;
      const date   = modal.querySelector('#poSupInvDate').value;
      po.supplierInvoice = { number, amount, date };
      // Check discrepancy: compare invoiced amount vs. PO expected amount
      // PO stores qty (grams) and unitPrice (per gram); the old formula used
      // weightOrdered/unitCost which are never set, so expected was always 0 and
      // no discrepancy ever flagged.
      const expectedAmt = (+po.qty || 0) * (+po.unitPrice || 0);
      po.invoiceDiscrepancy = expectedAmt > 0 && Math.abs(amount - expectedAmt) > 1;
      saveAll();
      renderPurchaseOrders();
      toast(t('common.save'), 'success');
      return true;
    }
  });
}

/* ============================================================
   Feature 1: Stock transfer between locations (move and/or split)
   ============================================================ */
async function openStockTransferModal(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const locs = (typeof locations !== 'undefined') ? locations : [];
  if (!locs.length) { toast(t('inv.transfer_no_locations') || 'Add a location first (Settings → Locations).', 'info'); return; }
  const isResin = item.materialType === 'resin';
  const unit = isResin ? 'mL' : (t('common.grams') || 'g');
  const curLoc = item.locationId ? (locs.find(l => l.id === item.locationId)?.name || '') : (t('inv.location_unassigned') || 'Unassigned');
  const maxQty = Math.round(+item.weight || 0);

  openFormModal({
    title: `${t('inv.transfer_title') || 'Transfer Stock'} — ${escapeHtml(item.material)}`,
    saveLabel: t('inv.transfer_confirm') || 'Transfer',
    sizeLg: false,
    bodyHtml: `
      <p style="font-size:13px;color:var(--text-muted);margin:0 0 12px;">
        ${escapeHtml(t('inv.transfer_from') || 'From')}: <strong>${escapeHtml(curLoc)}</strong>
        · ${escapeHtml(t('inv.current_stock') || 'In stock')}: <strong>${maxQty} ${escapeHtml(unit)}</strong>
      </p>
      <label>${escapeHtml(t('inv.transfer_to') || 'To location')}</label>
      <select id="stDest">
        <option value="">${escapeHtml(t('inv.location_unassigned') || 'Unassigned')}</option>
        ${locs.map(l => `<option value="${escapeHtml(l.id)}"${item.locationId === l.id ? ' disabled' : ''}>${escapeHtml(l.name)}${item.locationId === l.id ? ' ('+escapeHtml(t('inv.transfer_current')||'current')+')' : ''}</option>`).join('')}
      </select>
      <label style="margin-top:12px;">${escapeHtml(t('inv.transfer_qty') || 'Quantity to move')} (${escapeHtml(unit)})</label>
      <input type="number" id="stQty" min="1" max="${maxQty}" step="1" value="${maxQty}">
      <p style="font-size:11.5px;color:var(--text-dim);margin-top:6px;">
        ${escapeHtml(t('inv.transfer_split_hint') || 'Moving less than the full amount splits the spool: a new spool is created at the destination.')}
      </p>`,
    async onSave(modal) {
      const destRaw = modal.querySelector('#stDest').value || '';
      const dest = destRaw || undefined;
      const qty = Math.round(num(modal.querySelector('#stQty').value, 0));
      if ((dest || null) === (item.locationId || null)) { toast(t('inv.transfer_same') || 'Pick a different location.', 'error'); return false; }
      if (qty <= 0) { toast(t('inv.transfer_qty_invalid') || 'Enter a quantity greater than zero.', 'error'); return false; }
      if (qty > maxQty) { toast(t('inv.transfer_qty_over') || 'Not enough stock to transfer.', 'error'); return false; }
      const destName = dest ? (locs.find(l => l.id === dest)?.name || '') : (t('inv.location_unassigned') || 'Unassigned');
      const ok = await confirmModal(
        (t('inv.transfer_confirm_msg', { qty, unit, dest: destName }) ||
         `Move ${qty}${unit} to ${destName}?`));
      if (!ok) return false;
      if (qty >= maxQty) {
        // Move the whole spool.
        item.locationId = dest;
      } else {
        // Split: reduce source, create a new spool at the destination.
        item.weight = Math.max(0, (+item.weight || 0) - qty);
        const clone = {
          ...item,
          id: uid('INV'),
          weight: qty,
          locationId: dest,
          // Reset per-spool histories that should not carry to the split-off spool.
          usageHistory: [],
          adjustments: [],
          priceHistory: (item.priceHistory || []).slice(),
        };
        inventory.push(clone);
      }
      saveAll();
      renderInventory();
      toast(t('inv.transfer_done') || 'Stock transferred', 'success');
      return true;
    }
  });
}

/* ============================================================
   Feature 2: Spool QR/barcode label (reuses hubAPI.generateQR + print path)
   ============================================================ */
async function printSpoolLabel(itemId) {
  const item = inventory.find(i => i.id === itemId);
  if (!item) return;
  const shopName = (typeof settings !== 'undefined' && (shopField('biz'))) || 'Khayt';
  const isResin = item.materialType === 'resin';
  const unit = isResin ? 'mL' : 'g';
  const weightStr = `${Math.round(+item.weight || 0)} ${unit}`;
  const colorHex = safeCssColor(item.color, '#888888');
  // Dry-by date: 30 days after last drying (hygroscopic spools), else blank.
  let dryByStr = '';
  const dryLog = item.dryingLog || [];
  if (dryLog.length) {
    const last = [...dryLog].sort((a, b) => (b.date || '').localeCompare(a.date || ''))[0];
    if (last && last.date) {
      const due = new Date(last.date + 'T00:00:00');
      due.setDate(due.getDate() + 30);
      dryByStr = localDateStr(due);
    }
  }
  const locName = item.locationId && typeof locations !== 'undefined'
    ? (locations.find(l => l.id === item.locationId)?.name || '') : '';

  // QR payload: compact, parseable key/value lines (matches NFC-style fields).
  const qrPayload = [
    `KHAYT-SPOOL`,
    `id:${item.id}`,
    `material:${item.material || ''}`,
    `color:${item.colourVariant || item.color || ''}`,
    `weight:${weightStr}`,
    dryByStr ? `dryBy:${dryByStr}` : '',
  ].filter(Boolean).join('\n');

  let qrSvg = '';
  if (window.hubAPI?.generateQR) {
    try { qrSvg = await window.hubAPI.generateQR(qrPayload, { width: 120, margin: 0 }); }
    catch (e) { /* graceful fallback — no QR */ }
  }

  const L = (k, fb) => escapeHtml(t(k) || fb);
  const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>${L('inv.spool_label', 'Spool Label')} — ${escapeHtml(item.id)}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family:-apple-system,'Segoe UI',sans-serif; background:#fff; color:#111; }
  .label { width:62mm; min-height:40mm; border:1px solid #ccc; border-radius:2mm;
    padding:3mm 4mm; display:flex; gap:3mm; page-break-after:always; }
  .info { flex:1; display:flex; flex-direction:column; gap:1mm; }
  .shop { font-size:6.5pt; color:#888; font-weight:600; text-transform:uppercase; letter-spacing:.3pt; }
  .mat { font-size:10pt; font-weight:800; line-height:1.15; display:flex; align-items:center; gap:2mm; }
  .swatch { width:4mm; height:4mm; border-radius:50%; border:0.3mm solid #999; flex-shrink:0; }
  .meta { font-size:7pt; color:#555; display:flex; flex-wrap:wrap; gap:1mm 2.5mm; margin-top:1mm; }
  .meta span { background:#f3f4f6; border-radius:1.5mm; padding:0.4mm 1.5mm; }
  .id { font-family:monospace; font-size:6.5pt; color:#999; margin-top:auto; }
  .qr { width:18mm; height:18mm; flex-shrink:0; }
  .qr svg { width:100%; height:100%; }
  @media print { body { -webkit-print-color-adjust:exact; print-color-adjust:exact; } }
</style>
</head>
<body>
<div class="label">
  <div class="info">
    <div class="shop">${escapeHtml(shopName)}</div>
    <div class="mat"><span class="swatch" style="background:${colorHex};"></span>${escapeHtml(item.material || '—')}</div>
    <div class="meta">
      ${item.colourVariant ? `<span>${escapeHtml(item.colourVariant)}</span>` : ''}
      <span>${escapeHtml(weightStr)}</span>
      ${item.lot ? `<span>${L('inv.lot', 'Lot')}: ${escapeHtml(item.lot)}</span>` : ''}
      ${locName ? `<span>${escapeHtml(locName)}</span>` : ''}
      ${dryByStr ? `<span>${L('inv.dry_by', 'Dry by')} ${escapeHtml(dryByStr)}</span>` : ''}
    </div>
    <div class="id">${escapeHtml(item.id)}</div>
  </div>
  ${qrSvg ? `<div class="qr">${qrSvg}</div>` : ''}
</div>
<script>window.onload = () => { setTimeout(() => window.print(), 250); };<\/script>
</body></html>`;

  const printable = typeof sanitizePrintHtml === 'function' ? sanitizePrintHtml(html) : html;
  const win = window.open('', '_blank', 'width=360,height=280,toolbar=0,menubar=0,scrollbars=0');
  if (win) {
    win.document.open();
    win.document.write(printable);
    win.document.close();
  } else if (window.hubAPI?.saveHtml) {
    const saved = await window.hubAPI.saveHtml(html, `spool-label-${item.id}.html`);
    if (saved?.path) window.hubAPI?.openPath?.(saved.path);
    toast((_invBdr ? '' : '🏷 ') + (t('inv.label_generated') || 'Label generated'), 'success');
  }
}

  const api = {

    partGramsConsumed,
    isLowStock,
    spoolMatchesLocation,
    filterInventoryByLocation,
    perLocationLowStockCounts,
    orderSpoolsByLocationPreference,
    openStockTransferModal,
    printSpoolLabel,
    importSpoolsCsv,
    importClientsCsv,
    importProductsCsv,
    openFilamentCatalog,
    openFilamentScanner,
    addInventoryItem,
    deleteInventoryItem,
    deleteSupplier,
    deleteProduct,
    openInventoryEditor,
    openPriceHistory,
    checkSpoolOvercommit,
    todayPlusDays,
    getQueuedWeight,
    getSpoolReservedGrams,
    renderInventory,
    openStockAdjustModal,
    openSpoolHistory,
    openDryingLog,
    openTestPrintLog,
    deductFilamentForOrder,
    deductPackagingConsumables,
    renderConsumables,
    setConsCategoryFilter,
    openConsumableEditor,
    deleteConsumable,
    renderSupplierReorderList,
    renderSuppliers,
    openSupplierEditor,
    openLogPurchaseModal,
    openSupplierHistory,
    getProductStats,
    renderCatalog,
    quoteFromProduct,
    quoteFromBundle,
    openBundlesModal,
    openProductEditor,
    resizeImage,
    computeMaterialForecast,
    estimateDaysRemaining,
    renderProductTierChips,
    batchGenPOs,
    createPurchaseOrder,
    renderPurchaseOrders,
    openReorderModal,
    openReorderSuggestions,
    maybeAutoDraftPurchaseOrders,
    exportInventoryCsv,
    openShoppingList,
    recordSupplierInvoice,
    // Groups and categories. Everything here is called from ANOTHER file —
    // wire-events.js dispatches the chips, settings.js builds the storefront
    // payload — and this file is an IIFE, so an unexported one is a control that
    // renders and throws. test/cross-file-calls.test.js is what says so.
    organiseKnown,
    organiseOptions,
    organiseAssign,
    productGroupOf,
    productCategoryOf,
    renderCatalogFilters,
    filterCatalogBy,
    catFilterValue,
    bundleMembers,
  };
  Object.assign(global, api);
  global.KhaytInventory = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
