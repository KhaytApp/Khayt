'use strict';
(function () {
/**
 * Sample / demo data — a small, realistic set of clients, products, spools,
 * machines, and orders so a new shop can explore Khayt before entering real
 * data. Pure (no DOM/globals): the renderer merges the result into the live
 * collections (dedup by id) and can later strip it (every record carries
 * `sample: true` and a stable `DEMO-*` id). Dates are relative to `opts.today`
 * so the demo always looks current; deterministic for tests.
 */

function daysAgo(todayIso, n) {
  const d = new Date((todayIso || '2026-01-01') + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}

/** @param {{today?:string}} [opts] @returns {object} collections to merge in. */
function buildSampleData(opts) {
  opts = opts || {};
  const today = opts.today || '2026-01-01';
  const S = (o) => Object.assign({ sample: true }, o);
  const hist = (status, date) => [{ status, at: date + 'T09:00:00.000Z' }];

  const machines = [
    S({ id: 'DEMO-M1', name: 'Demo · Bambu A1', model: 'Bambu Lab A1', status: 'idle' }),
    S({ id: 'DEMO-M2', name: 'Demo · Ender 3 V3', model: 'Creality Ender 3 V3', status: 'idle' }),
  ];
  const clients = [
    S({ id: 'DEMO-C1', nameEn: 'Layla Design Studio', nameAr: 'استوديو ليلى', phone: '+966500000001', email: 'layla@example.com', source: 'sample' }),
    S({ id: 'DEMO-C2', nameEn: 'Gulf Robotics Lab', nameAr: 'مختبر الخليج للروبوتات', phone: '+966500000002', email: 'lab@example.com', source: 'sample' }),
    S({ id: 'DEMO-C3', nameEn: 'Cosplay Crafts', nameAr: 'كوسبلاي كرافتس', phone: '+966500000003', email: 'cosplay@example.com', source: 'sample' }),
  ];
  const products = [
    S({ id: 'DEMO-P1', nameEn: 'Desk Phone Stand', nameAr: 'حامل هاتف للمكتب', category: 'Office', price: 35, material: 'PLA', printTime: 2.5 }),
    S({ id: 'DEMO-P2', nameEn: 'Robotics Gear Set', nameAr: 'مجموعة تروس', category: 'Parts', price: 90, material: 'PETG', printTime: 6 }),
    S({ id: 'DEMO-P3', nameEn: 'Cosplay Helmet', nameAr: 'خوذة كوسبلاي', category: 'Props', price: 320, material: 'PLA', printTime: 22 }),
  ];
  const inventory = [
    S({ id: 'DEMO-S1', material: 'PLA', color: 'Black', brand: 'Demo Filament', weight: 850, costPerKg: 45, reorderPoint: 200 }),
    S({ id: 'DEMO-S2', material: 'PETG', color: 'Clear', brand: 'Demo Filament', weight: 150, costPerKg: 60, reorderPoint: 200 }),
    S({ id: 'DEMO-S3', material: 'PLA', color: 'Red', brand: 'Demo Filament', weight: 1000, costPerKg: 45, reorderPoint: 200 }),
  ];
  const part = (material, g, hrs, qty) => ({ material, printWeight: g, supportWeight: 0, printTime: hrs, qty: qty || 1, baseCost: 0 });
  const printLog = [
    S({ id: 'DEMO-O1', date: daysAgo(today, 1), timestamp: daysAgo(today, 1) + 'T09:00:00.000Z', project: 'Phone stands ×10', clientId: 'DEMO-C1', material: 'PLA', printTime: 25, price: 350, status: 'quote', statusHistory: hist('quote', daysAgo(today, 1)), paymentStatus: 'unpaid', paidAmount: 0, parts: [part('PLA', 60, 2.5, 10)], tags: ['sample'] }),
    S({ id: 'DEMO-O2', date: daysAgo(today, 3), timestamp: daysAgo(today, 3) + 'T09:00:00.000Z', project: 'Gear set prototype', clientId: 'DEMO-C2', machineId: 'DEMO-M2', material: 'PETG', printTime: 6, price: 90, status: 'printing', statusHistory: hist('printing', daysAgo(today, 3)), paymentStatus: 'partial', paidAmount: 30, parts: [part('PETG', 120, 6, 1)], dueDate: daysAgo(today, -2), tags: ['sample'] }),
    S({ id: 'DEMO-O3', date: daysAgo(today, 6), timestamp: daysAgo(today, 6) + 'T09:00:00.000Z', project: 'Helmet build', clientId: 'DEMO-C3', machineId: 'DEMO-M1', material: 'PLA', printTime: 22, price: 320, status: 'completed', statusHistory: hist('completed', daysAgo(today, 6)), completedAt: daysAgo(today, 2) + 'T18:00:00.000Z', paymentStatus: 'paid', paidAmount: 320, dueDate: daysAgo(today, 1), parts: [part('PLA', 600, 22, 1)], tags: ['sample'] }),
    S({ id: 'DEMO-O4', date: daysAgo(today, 14), timestamp: daysAgo(today, 14) + 'T09:00:00.000Z', project: 'Repeat phone stands', clientId: 'DEMO-C1', machineId: 'DEMO-M1', material: 'PLA', printTime: 5, price: 70, status: 'delivered', statusHistory: hist('delivered', daysAgo(today, 14)), completedAt: daysAgo(today, 12) + 'T18:00:00.000Z', paymentStatus: 'paid', paidAmount: 70, dueDate: daysAgo(today, 11), parts: [part('PLA', 60, 2.5, 2)], tags: ['sample'] }),
    S({ id: 'DEMO-O5', date: daysAgo(today, 0), timestamp: daysAgo(today, 0) + 'T09:00:00.000Z', project: 'New enquiry', clientId: 'DEMO-C2', material: 'PETG', printTime: 4, price: 60, status: 'pending', statusHistory: hist('pending', daysAgo(today, 0)), paymentStatus: 'unpaid', paidAmount: 0, parts: [part('PETG', 80, 4, 1)], tags: ['sample'] }),
  ];

  return { machines, clients, products, inventory, printLog };
}

/** Collection names sample data spans (for merge + strip). */
const SAMPLE_COLLECTIONS = ['machines', 'clients', 'products', 'inventory', 'printLog'];

const api = { buildSampleData, SAMPLE_COLLECTIONS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytSampleData = api;
})();
