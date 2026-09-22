#!/usr/bin/env node
/**
 * E2E: a "Copy link" button really puts the link on the clipboard.
 *
 * Reported from the field: with cloud sync connected, the Shopify import/feed
 * links in Settings → Storefronts & Payments render as live buttons, the panel
 * answers "✓ Import link copied", and pasting produces nothing.
 *
 * The cause was two layers deep and neither layer could be seen from a unit
 * test. main.js grants renderer permissions from an allow-list that did not
 * include 'clipboard-sanitized-write' — the permission Chromium checks on every
 * navigator.clipboard.writeText() — so all ~25 copy buttons in the app rejected
 * with NotAllowedError. Each call site then swallowed the rejection and claimed
 * success anyway, which is why an app-wide outage read as working.
 *
 * So this test asserts against the real OS clipboard, read back from the main
 * process. Asserting that writeText() resolved would have passed all along.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const SENTINEL = 'CLIPBOARD-NOT-WRITTEN';
const CLOUD = { enabled: true, url: 'https://cloud.example.test', shopId: 'shop_e2e' };

let electronApp;
let failures = 0;

/** Read what actually landed on the OS clipboard, from the main process. */
const osClipboard = () => electronApp.evaluate(({ clipboard }) => clipboard.readText());
const poison = () => electronApp.evaluate(({ clipboard }, s) => clipboard.writeText(s), SENTINEL);

function check(label, actual, expected) {
  if (actual === expected) { console.log(`  ok   ${label}`); return; }
  failures++;
  console.log(`  FAIL ${label}\n       expected: ${JSON.stringify(expected)}\n       actual:   ${JSON.stringify(actual)}`);
}

/** The permission the whole thing hinged on — assert it directly. */
async function testTheClipboardPermissionIsGranted(window) {
  const probe = await window.evaluate(async () => {
    try { await navigator.clipboard.writeText('permission-probe'); return 'resolved'; }
    catch (e) { return `${e.name}: ${e.message}`; }
  });
  check('navigator.clipboard.writeText is permitted', probe, 'resolved');
}

/** Reading is deliberately still denied — the app never pastes for the user. */
async function testClipboardReadStaysDenied(window) {
  const probe = await window.evaluate(async () => {
    try { await navigator.clipboard.readText(); return 'resolved'; }
    catch (e) { return e.name; }
  });
  check('navigator.clipboard.readText stays denied', probe, 'NotAllowedError');
}

/** David's button: click it, then look at the clipboard rather than the toast. */
async function testStorefrontImportLinkReachesTheClipboard(window) {
  await window.evaluate((cloud) => {
    /* Storefronts & Payments is a .pro-only CARD — Simple mode hides it in CSS.
     *
     * It lives under `online`, not `automation`: a section called "Online" that
     * held only LAN features while the storefront and cloud sync sat under
     * "Automation" was the wrong way round. The card kept its `pro-only` class
     * through the move, so this still has to switch to professional mode — the
     * class is on the card now rather than inherited from the nav item. */
    settings.mode = 'professional';
    KhaytShell.applyMode();
    settings.cloud = cloud;
    /* PIN THE MARKET, because this test is about the clipboard.
     *
     * The directory opens on where the shop sells — its country, then its
     * currency, then the interface language. This shop states neither, and
     * Khayt's default currency is SAR, so it would open on the Gulf market and
     * the first copy button would be Salla. That is correct behaviour and has
     * its own tests; what it must not do is decide which URL a clipboard test
     * is asserting on. So the shop says where it is, and this stays a test of
     * the copy button. */
    settings.country = 'US';
    KhaytShell.openSettingsSection('online');
    renderIntegrationsSettings();
  }, CLOUD);

  const btn = window.locator('#integrationsSection .integCopy').first();
  await btn.waitFor({ state: 'visible', timeout: 15_000 });
  const url = await btn.getAttribute('data-url');
  check('the Shopify import link is the first copy button (a US shop)',
    url, `${CLOUD.url}/v1/shops/${CLOUD.shopId}/import/shopify`);

  await poison();
  await btn.click();
  await window.waitForFunction(
    (s) => !/^✓?\s*$/.test(document.querySelector('#integResult')?.textContent || '') || s === null,
    null, { timeout: 5_000 },
  ).catch(() => {});
  check('the import link is on the clipboard', await osClipboard(), url);
}

/** The panel must not claim success when the copy failed. */
async function testTheSuccessMessageTracksTheCopy(window) {
  const said = await window.evaluate(() => document.querySelector('#integResult')?.textContent || '');
  check('the panel confirms the copy', said.startsWith('✓'), true);

  // Force the failure path and confirm the message follows it. The lever is the
  // shared helper, not hubAPI — contextBridge freezes that object, so stubbing
  // window.hubAPI.clipboardWrite silently does nothing and the copy succeeds.
  const onFailure = await window.evaluate(async () => {
    const real = globalThis.copyText;
    globalThis.copyText = async () => false;
    try {
      document.querySelector('#integrationsSection .integCopy').click();
      await new Promise((r) => setTimeout(r, 300));
      return document.querySelector('#integResult')?.textContent || '';
    } finally {
      globalThis.copyText = real;
    }
  });
  check('a failed copy is reported as a failure', /copy failed/i.test(onFailure), true);
  check('a failed copy does not claim success', onFailure.startsWith('✓'), false);
}

/** The shared helper works where navigator.clipboard cannot: no user gesture. */
async function testCopyTextWorksWithoutAUserGesture(window) {
  await poison();
  const ok = await window.evaluate(() => copyText('no-gesture-required'));
  check('copyText resolves true with no user activation', ok, true);
  check('copyText wrote through to the OS clipboard', await osClipboard(), 'no-gesture-required');
}

/** The recovery code kept its own copy of the IPC-first logic; it now shares one. */
async function testRecoveryCodeStillCopies(window) {
  await poison();
  const res = await window.evaluate(() => copyRecoveryCode('abcd1234efgh5678'));
  check('copyRecoveryCode reports ok', res?.ok, true);
  const formatted = await window.evaluate(() => formatRecoveryCode('abcd1234efgh5678'));
  check('the formatted recovery code is on the clipboard', await osClipboard(), formatted);
}

/** Empty input must not silently wipe whatever the user already had copied. */
async function testCopyTextRefusesEmptyInput(window) {
  await poison();
  const ok = await window.evaluate(() => copyText(''));
  check('copyText refuses empty text', ok, false);
  check('copyText left the clipboard untouched', await osClipboard(), SENTINEL);
}

const userData = makeUserDataDir();
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const { window } = launched;
  await dismissWizard(window);

  for (const test of [
    testTheClipboardPermissionIsGranted,
    testClipboardReadStaysDenied,
    testStorefrontImportLinkReachesTheClipboard,
    testTheSuccessMessageTracksTheCopy,
    testCopyTextWorksWithoutAUserGesture,
    testRecoveryCodeStillCopies,
    testCopyTextRefusesEmptyInput,
  ]) {
    console.log(`\n${test.name}`);
    await test(window);
  }
} finally {
  await electronApp?.close();
}

console.log(failures ? `\n${failures} check(s) failed` : '\nclipboard smoke ok');
process.exit(failures ? 1 : 0);
