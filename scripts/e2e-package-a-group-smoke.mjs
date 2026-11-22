#!/usr/bin/env node
/**
 * E2E: a collection offered as one package.
 *
 * Asked for as "group like the saudi kings … easier to find and offer as a
 * package". Khayt already had the package — a bundle, quotable in one tap — but
 * the only way to build one was to tick every product by hand, and it FROZE at
 * that moment: an eighth king joined the collection and the package stayed at
 * seven, with nothing saying so.
 *
 * What it proves:
 *   a group with two or more products is offered as a package, in one press;
 *   the package FOLLOWS the group — a product filed later joins it;
 *   quoting the package puts every member's parts in the build;
 *   a group already packaged is not offered twice;
 *   a hand-picked bundle still works and is not migrated.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

const part = (n) => ({ id: 'PRT-' + n, material: 'PLA', grams: 40, hours: 2, qty: 1 });

async function seed(window) {
  await window.evaluate(() => {
    if (!Array.isArray(window.products)) products = [];
    products.length = 0;
    const mk = (id, name, group) => ({
      id, nameEn: name, nameAr: '', description: '', defaultMargin: 30,
      priceTiers: [], parts: [{ id: 'PRT-' + id, material: 'PLA', grams: 40, hours: 2, qty: 1 }],
      createdAt: '2026-09-03', group: group || '', category: 'Busts',
    });
    products.push(mk('P1', 'King Abdulaziz', 'Saudi Kings'));
    products.push(mk('P2', 'King Saud', 'Saudi Kings'));
    products.push(mk('P3', 'Cable clip', ''));
    products.push(mk('P4', 'Lone dragon', 'Dragons'));   // one member only
    if (!settings.bundles) settings.bundles = [];
    settings.bundles.length = 0;
    renderCatalog();
  });
  await window.waitForSelector('.product-card[data-id="P1"]');
}

const openBundles = async (window) => {
  await window.evaluate(() => openBundlesModal());
  await window.waitForSelector('#bundleList');
};
const closeModal = async (window) => {
  await window.evaluate(() => document.querySelector('.modal [data-act="cancel"]')?.click());
  await window.waitForSelector('#bundleList', { state: 'detached' }).catch(() => {});
};
const offers = (window) => window.evaluate(() =>
  [...document.querySelectorAll('[data-bgroup]')].map((b) => b.dataset.bgroup));
const bundles = (window) => window.evaluate(() => JSON.parse(JSON.stringify(settings.bundles || [])));

async function testOnlyRealCollectionsAreOffered(window) {
  await openBundles(window);
  const list = await offers(window);
  if (!list.includes('Saudi Kings')) throw new Error(`a group of two was not offered as a package: ${list}`);
  // A group of one is not a collection, and an ungrouped product is not a group.
  if (list.includes('Dragons')) throw new Error('a group with a single product was offered as a package');
  if (list.some((x) => !x)) throw new Error('the ungrouped bucket was offered as a package');
}

async function testOnePressMakesIt(window) {
  await window.click('[data-bgroup="Saudi Kings"]');
  await window.waitForTimeout(120);
  const b = (await bundles(window))[0];
  if (!b) throw new Error('no package was made');
  if (b.name !== 'Saudi Kings') throw new Error(`the package is not named after the group: ${b.name}`);
  // FOLLOWS the group — it does not freeze a list of ids.
  if (b.group !== 'Saudi Kings') throw new Error(`the package pinned ids instead of following the group: ${JSON.stringify(b)}`);
  if (b.productIds) throw new Error(`the package froze its members: ${JSON.stringify(b.productIds)}`);
  const members = await window.evaluate(() => bundleMembers(settings.bundles[0]).map((p) => p.id));
  if (members.join() !== 'P1,P2') throw new Error(`the package holds ${members}`);
}

async function testItIsNotOfferedTwice(window) {
  await openBundles(window);
  const list = await offers(window);
  if (list.includes('Saudi Kings')) throw new Error('a group that is already a package was offered again');
  await closeModal(window);
}

async function testANewMemberJoinsIt(window) {
  // The whole reason this follows the group rather than freezing.
  await window.evaluate(() => {
    products.push({ id: 'P5', nameEn: 'King Faisal', nameAr: '', description: '', defaultMargin: 30,
      priceTiers: [], parts: [{ id: 'PRT-P5', material: 'PLA', grams: 40, hours: 2, qty: 1 }],
      createdAt: '2026-09-03', group: 'Saudi Kings', category: 'Busts' });
    saveAll(); renderCatalog();
  });
  const members = await window.evaluate(() => bundleMembers(settings.bundles[0]).map((p) => p.id));
  if (members.join() !== 'P1,P2,P5') {
    throw new Error(`a product filed into the group did not join the package: ${members}`);
  }
}

async function testQuotingThePackageBuildsAllOfIt(window) {
  await window.evaluate(() => { currentBuild.length = 0; quoteFromBundle(settings.bundles[0].id); });
  await window.waitForTimeout(150);
  const n = await window.evaluate(() => currentBuild.length);
  if (n !== 3) throw new Error(`quoting the package put ${n} parts in the build, expected 3`);
}

async function testAHandPickedBundleStillWorks(window) {
  await window.evaluate(() => {
    settings.bundles.push({ id: 'BND-OLD', name: 'Desk set', productIds: ['P3', 'P4'], createdAt: '2026-01-01' });
    saveAll();
  });
  const members = await window.evaluate(() => bundleMembers(settings.bundles[1]).map((p) => p.id));
  if (members.join() !== 'P3,P4') throw new Error(`an existing pinned bundle broke: ${members}`);
  // …and it shows in the list beside the group-backed one.
  await openBundles(window);
  const names = await window.evaluate(() => [...document.querySelectorAll('#bundleList [data-bid]')].map((c) => c.textContent.replace(/\s+/g, ' ').trim()));
  if (names.length !== 2) throw new Error(`the list shows ${names.length} packages, expected 2`);
  if (!names.some((x) => /Desk set/.test(x) && /Cable clip/.test(x))) throw new Error(`the pinned bundle lost its members: ${names}`);
  if (!names.some((x) => /Saudi Kings/.test(x) && /King Faisal/.test(x))) {
    throw new Error(`the group package does not list its current members: ${names}`);
  }
  await closeModal(window);
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'catalog-tab');
  await seed(window);

  await testOnlyRealCollectionsAreOffered(window);
  await testOnePressMakesIt(window);
  await testItIsNotOfferedTwice(window);
  await testANewMemberJoinsIt(window);
  await testQuotingThePackageBuildsAllOfIt(window);
  await testAHandPickedBundleStillWorks(window);

  console.log('e2e-package-a-group: ok (offered once, made in one press, follows the group, quotes whole, pinned bundles untouched)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
