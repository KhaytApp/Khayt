#!/usr/bin/env node
/**
 * E2E: pickup hours and a map link reach the customer's order page.
 *
 * Settings ▸ Operations has Pickup hours and Map link beside the payment
 * instructions. Saving the form runs the shared rule (lib/settings-edit.js),
 * which keeps an https link and drops anything else, and the order page
 * payload (lib/portal-refresh.js) then carries payload.pickup for a job that
 * is not with a courier. A shipped job and a quote get none, and a shop that
 * leaves both empty shows no pickup card. Same keys as the Mac (#2310).
 *
 *   node scripts/e2e-pickup-settings-smoke.mjs
 */
import fs from 'node:fs';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  const saveWith = (hours, map) => window.evaluate(([h, m]) => {
    loadSettingsIntoForm();
    document.querySelector('#set_pickupHours').value = h;
    document.querySelector('#set_pickupMapUrl').value = m;
    saveSettingsFromForm();
    return { hours: settings.pickupHours, map: settings.pickupMapUrl };
  }, [hours, map]);

  const payloads = () => window.evaluate(() => {
    const base = { date: localDateStr(), project: 'Vase', price: 50, parts: [] };
    return {
      open: buildPortalPayload({ ...base, id: 'ORD-pk1', status: 'pending' }).payload.pickup || null,
      shipped: buildPortalPayload({ ...base, id: 'ORD-pk2', status: 'completed', carrier: 'smsa', trackingNumber: '123' }).payload.pickup || null,
      quote: buildPortalPayload({ ...base, id: 'Q-pk3', status: 'quote' }).payload.pickup || null,
    };
  });

  // ---- an https link and hours are kept and sent ----
  const saved = await saveWith('  Sun–Thu 4–10 pm  ', 'https://maps.example.com/shop');
  if (saved.hours !== 'Sun–Thu 4–10 pm') fail(`hours not trimmed and kept: ${JSON.stringify(saved)}`);
  if (saved.map !== 'https://maps.example.com/shop') fail(`https map link not kept: ${JSON.stringify(saved)}`);
  const p = await payloads();
  if (!p.open || p.open.hours !== 'Sun–Thu 4–10 pm' || p.open.mapUrl !== 'https://maps.example.com/shop') {
    fail(`open job has no pickup card: ${JSON.stringify(p.open)}`);
  }
  if (p.shipped) fail(`a shipped job got a pickup card: ${JSON.stringify(p.shipped)}`);
  if (p.quote) fail(`a quote got a pickup card: ${JSON.stringify(p.quote)}`);

  // ---- the form shows what was saved ----
  const shown = await window.evaluate(() => {
    document.querySelector('#set_pickupHours').value = '';
    loadSettingsIntoForm();
    return document.querySelector('#set_pickupHours').value;
  });
  if (shown !== 'Sun–Thu 4–10 pm') fail(`form did not load the saved hours: "${shown}"`);

  // ---- a plain-http link is dropped; both empty means no card ----
  const http = await saveWith('', 'http://maps.example.com/shop');
  if (http.map !== '') fail(`an http link was kept: ${JSON.stringify(http)}`);
  const none = await payloads();
  if (none.open) fail(`empty hours and no link still sent a pickup card: ${JSON.stringify(none.open)}`);

  console.log('pickup settings smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
