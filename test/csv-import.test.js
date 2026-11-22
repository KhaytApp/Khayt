/**
 * lib/csv-import.js against the desktop code it was lifted from.
 *
 * The three `onImport` closures of renderer/inventory.js and the parse/map of
 * renderer/app-helpers.js + util.js are copied below AS THEY WERE before the
 * lift, and the same files go through both. The desktop now calls the lib and
 * the Mac runs it through JavaScriptCore, so this is what holds the two apps
 * to one answer for one spreadsheet.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const CSV = require('../lib/csv-import.js');

// ── The desktop as it was ────────────────────────────────────────────────

function oldParse(csv) {
  const lines = csv.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim().split('\n');
  if (!lines.length) return { headers: [], rows: [] };
  function parseLine(line) {
    const cols = []; let cur = ''; let inQ = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (c === '"') { if (inQ && line[i + 1] === '"') { cur += '"'; i++; } else inQ = !inQ; }
      else if (c === ',' && !inQ) { cols.push(cur.trim()); cur = ''; }
      else cur += c;
    }
    cols.push(cur.trim());
    return cols;
  }
  return { headers: parseLine(lines[0]), rows: lines.slice(1).filter((l) => l.trim()).map(parseLine) };
}

function oldAutoMapIdx(fieldKey, fieldLabel, headers) {
  const norm = (s) => s.toLowerCase().replace(/[\s_-]/g, '');
  const targets = [norm(fieldKey), norm(fieldLabel)];
  const idx = headers.findIndex((h) => targets.includes(norm(h)));
  return idx >= 0 ? String(idx) : '';
}

function oldObjects(parsedRows, fields, mappings) {
  return parsedRows.map((row) => {
    const obj = {};
    fields.forEach((f) => {
      if (mappings[f.key] >= 0) {
        const raw = row[mappings[f.key]]?.trim() || '';
        obj[f.key] = f.type === 'number' ? (+raw || 0) : raw;
      }
    });
    return obj;
  }).filter((obj) => fields.filter((f) => f.required).every((f) => obj[f.key]));
}

function oldSpools(rows, inventory, settings, uid, today) {
  let imported = 0, skipped = 0;
  rows.forEach((row) => {
    const exists = (inventory || []).some((s) =>
      s.material?.toLowerCase() === row.material?.toLowerCase() &&
      s.brand?.toLowerCase() === (row.brand || '').toLowerCase() &&
      s.color?.toLowerCase() === (row.color || '').toLowerCase());
    if (exists) { skipped++; return; }
    const wt = row.weightTotal || 1000;
    inventory.push({
      id: uid('S'), material: row.material, brand: row.brand || '', color: row.color || '',
      lot: row.lot || undefined, diameter: row.diameter || 1.75,
      weight: row.weightRemaining != null ? row.weightRemaining : wt, weightTotal: wt,
      cost: row.costPerKg || 0, reorderPoint: row.reorderPoint ?? (settings.lowStockThreshold ?? 200),
      location: row.location || '', notes: row.notes || '', addedAt: today, usageHistory: [],
    });
    imported++;
  });
  return { imported, skipped };
}

function oldClients(rows, clients, uid, today) {
  let imported = 0, skipped = 0;
  rows.forEach((row) => {
    const exists = (clients || []).some((c) =>
      (c.nameEn?.toLowerCase() === row.nameEn?.toLowerCase()) ||
      (row.phone && c.phone === row.phone) ||
      (row.email && c.email?.toLowerCase() === row.email?.toLowerCase()));
    if (exists) { skipped++; return; }
    clients.push({
      id: uid('CL'), nameEn: row.nameEn, nameAr: row.nameAr || '', phone: row.phone || '',
      email: row.email || '', city: row.city || '', address: row.address || '',
      vat: row.vatNumber || '', company: row.company || '', notes: row.notes || '',
      createdAt: today, commLog: [], loyaltyTier: 'standard',
    });
    imported++;
  });
  return { imported, skipped };
}

function oldProducts(rows, products, uid, today) {
  let imported = 0, skipped = 0;
  rows.forEach((row) => {
    const exists = (products || []).some((p) =>
      (p.nameEn?.toLowerCase() === row.nameEn?.toLowerCase()) || (row.sku && p.sku === row.sku));
    if (exists) { skipped++; return; }
    products.push({
      id: uid('PROD'), nameEn: row.nameEn, nameAr: row.nameAr || '', description: row.description || '',
      defaultMargin: row.defaultMargin || 30, sku: row.sku || '', thumbnail: null, imagePath: null,
      priceTiers: [], parts: [], createdAt: today,
    });
    imported++;
  });
  return { imported, skipped };
}

// ── Fixtures ─────────────────────────────────────────────────────────────

const counter = () => { let n = 0; return (p) => `${p}-${++n}`; };
const TODAY = '2026-11-06';

const SPOOLS = [
  'Material,Brand,Color,Lot,Diameter (mm),total_weight,Remaining (g),Cost/kg,Reorder Point (g),Location,Notes',
  'PLA,Bambu,Black,L1,1.75,1000,820,90,,Shelf A,"first, with a comma"',
  'pla,BAMBU,black,,,,,,,,duplicate of the first by case',
  'PETG,Prusament,"Galaxy ""Black""",,2.85,,abc,120,150,,quoted quote',
  ',NoMaterial,Red,,,,,,,,dropped: material is required',
  '',
  'ABS,Elegoo,White,,,750,,0,0,,',
  'PLA,Bambu,Red,,,,,,,,',
].join('\r\n');

const CLIENTS = [
  'name_en,Name (Arabic),Phone,Email,City,Address,VAT Number,Company,Notes',
  'Acme,أكمي,0500000001,ACME@x.com,Riyadh,,300000000000003,Acme Co,',
  'Beta,,0500000001,,,,,,same phone as Acme',
  'Gamma,,,acme@X.com,,,,,same email as Acme',
  'Delta,,,,,,,,',
  'acme,,,,,,,,same name',
  ',,0599999999,,,,,,no name',
].join('\n');

const PRODUCTS = [
  'nameEn,nameAr,Description,Default Margin (%),SKU',
  'Vase,مزهرية,A vase,45,V-1',
  'Lamp,,,,V-1',
  'vase,,,,',
  'Hook,,,0,H-1',
].join('\r');

function viaOld(kind, text, existing, settings) {
  const fields = CSV.FIELDS[kind];
  const { headers, rows } = oldParse(text);
  const mappings = {};
  fields.forEach((f) => { const i = oldAutoMapIdx(f.key, f.label, headers); mappings[f.key] = i !== '' ? +i : -1; });
  const objs = oldObjects(rows, fields, mappings);
  const book = JSON.parse(JSON.stringify(existing));
  const uid = counter();
  const r = kind === 'spools' ? oldSpools(objs, book, settings, uid, TODAY)
    : kind === 'clients' ? oldClients(objs, book, uid, TODAY) : oldProducts(objs, book, uid, TODAY);
  return { book: JSON.parse(JSON.stringify(book)), ...r, mappings, objs };
}

function viaLib(kind, text, existing, settings) {
  const fields = CSV.FIELDS[kind];
  const { headers, rows } = CSV.parse(text);
  const mappings = CSV.autoMap(fields, headers);
  const objs = CSV.objects(rows, fields, mappings);
  const book = JSON.parse(JSON.stringify(existing));
  const out = CSV.plan(kind, objs, book, { today: TODAY, settings, newId: counter() });
  book.push(...out.add);
  return { book: JSON.parse(JSON.stringify(book)), imported: out.imported, skipped: out.skipped, mappings, objs, out };
}

const EXISTING = {
  spools: [{ id: 'S-old', material: 'PLA', brand: 'Bambu', color: 'Red', weight: 10 }],
  clients: [{ id: 'CL-old', nameEn: 'Zeta', phone: '0511111111' }],
  products: [{ id: 'PROD-old', nameEn: 'Hook', sku: '' }],
};

for (const [kind, text] of [['spools', SPOOLS], ['clients', CLIENTS], ['products', PRODUCTS]]) {
  for (const settings of [{}, { lowStockThreshold: 75 }]) {
    test(`${kind}: the lib builds what the desktop built (settings ${JSON.stringify(settings)})`, () => {
      const was = viaOld(kind, text, EXISTING[kind], settings);
      const now = viaLib(kind, text, EXISTING[kind], settings);
      assert.deepEqual(now.mappings, was.mappings);
      assert.deepEqual(now.objs, was.objs);
      assert.deepEqual(now.book, was.book);
      assert.equal(now.imported, was.imported);
      assert.equal(now.skipped, was.skipped);
    });
  }
}

test('the parse is renderer/util.js parseCsvString, on awkward input', () => {
  for (const text of ['', 'a', 'a,b\n', '"x,y",z\n"1",""\n\n\n3,4', ' h1 , h2 \r\n v1 , "v ""2"" " ']) {
    assert.deepEqual(CSV.parse(text), oldParse(text), JSON.stringify(text));
  }
});

test('a label in the shop\'s language maps its column', () => {
  const m = CSV.autoMap(CSV.FIELDS.clients, ['الاسم', 'phone'], { nameEn: 'الاسم' });
  assert.equal(m.nameEn, 0);
  assert.equal(m.phone, 1);
  assert.equal(m.email, -1);
});

test('the preview says which rows are new and which are already in the book', () => {
  const now = viaLib('spools', SPOOLS, EXISTING.spools, {});
  assert.deepEqual(now.out.rows.map((r) => r.verdict), ['new', 'duplicate', 'new', 'new', 'duplicate']);
  assert.equal(now.out.rows[0].id, now.out.add[0].id);
});

test('ids handed in are used in order, and running out is an error, not a blank id', () => {
  const objs = [{ nameEn: 'One' }, { nameEn: 'Two' }];
  const out = CSV.plan('products', objs, [], { today: TODAY, ids: ['PROD-a', 'PROD-b'] });
  assert.deepEqual(out.add.map((p) => p.id), ['PROD-a', 'PROD-b']);
  assert.throws(() => CSV.plan('products', objs, [], { today: TODAY, ids: ['PROD-a'] }));
});

test('every field names a word the shared catalogue has', () => {
  require('../renderer/locales/en.js');
  const en = globalThis.KhaytLocales.en;
  for (const kind of Object.keys(CSV.FIELDS)) {
    for (const f of CSV.FIELDS[kind]) assert.ok(en[f.labelKey], `${kind}.${f.key}: ${f.labelKey}`);
  }
});
