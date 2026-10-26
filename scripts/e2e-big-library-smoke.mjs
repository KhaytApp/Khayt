#!/usr/bin/env node
/**
 * E2E: a library the size of a real one.
 *
 * Measured before this existed: painting every card cost 95 ms at 400 records
 * and 701 ms at 3,415 — paid on every filter press, every star, and every round
 * of the thumbnail migration v3.7.0-beta.24 runs. Nearly a second of frozen
 * window, on the screen this app is for.
 *
 * A page is drawn now and the rest arrives as you reach it. What that must NOT
 * change is what anything MEANS: the filters still narrow the whole library, the
 * counts still count all of it, and "select all shown" still holds every match
 * rather than the hundred and twenty that happen to be painted.
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;
const N = 1200;              // enough to page several times; fast enough for CI

async function seed(window, n) {
  await window.evaluate((count) => {
    if (!Array.isArray(window.printFiles)) printFiles = [];
    printFiles.length = 0;
    for (let i = 0; i < count; i++) {
      printFiles.push({
        id: 'BIG-' + i, name: 'Model ' + i, originalName: 'm' + i + '.stl',
        createdAt: Date.now(), updatedAt: Date.now() - i,
        sourceFile: { filename: 'm' + i + '.stl', originalName: 'm' + i + '.stl', size: 4200000, ext: 'stl', kind: 'model' },
        parsed: {}, colors: [], tags: i % 5 === 0 ? ['resin'] : [],
        // Kings every 100, categories every 3 — so the two axes CROSS: 4 of the
        // 12 kings are Busts. With `i % 2` every king was a Bust and a count
        // that ignored the other axis was indistinguishable from one that did
        // not, which is how the first version of this test passed on a bug.
        group: i % 100 === 0 ? 'Saudi Kings' : '', category: i % 3 === 0 ? 'Busts' : 'Minis',
        thumb: null, thumbFile: null, material: 'PLA', favorite: false,
      });
    }
    renderPrintFiles();
  }, n);
  await window.waitForSelector('.pf-card');
}

const painted = (window) => window.evaluate(() => document.querySelectorAll('#printfiles-tab .pf-card').length);
const moreLabel = (window) => window.evaluate(() => document.querySelector('.pf-more-n')?.textContent.trim() || '');

async function testOnlyAPageIsPainted(window) {
  const n = await painted(window);
  if (n >= N) throw new Error(`every card was painted (${n}) — the whole point is that it is not`);
  if (n < 20) throw new Error(`only ${n} cards painted; that is not a usable page`);
  const label = await moreLabel(window);
  // The count must speak for the LIBRARY, not the page.
  if (!label.includes(String(N))) throw new Error(`the count does not say how many there really are: "${label}"`);
}

async function testScrollingGrowsThePageWithoutPressingAnything(window) {
  // The observer is attached by renderList(); renderPrintFiles() builds the
  // tab's markup ITSELF and did not attach it, so the first screen a shop saw
  // stopped at one page until the button was pressed. The button works, which
  // is why pressing it was not a test of this.
  const before = await painted(window);
  await window.evaluate(() => document.getElementById('pfMore')?.scrollIntoView({ block: 'center' }));
  await window.waitForTimeout(400);
  const after = await painted(window);
  if (after <= before) {
    throw new Error(`scrolling to the end painted ${after}, was ${before} — the observer is not attached on a fresh render`);
  }
}

async function testTheRestArrivesWhenAskedFor(window) {
  const before = await painted(window);
  await window.click('[data-act="pf-more"]');
  await window.waitForTimeout(120);
  const after = await painted(window);
  if (after <= before) throw new Error(`asking for more painted ${after}, was ${before}`);
}

async function testFiltersNarrowTheWholeLibraryNotThePage(window) {
  // 12 of the 1200 are Saudi Kings, and none of them is in the first page —
  // a filter that only searched what was painted would find nothing.
  await window.click('.pf-folderbar [data-folder="Saudi Kings"]');
  await window.waitForTimeout(120);
  const n = await painted(window);
  if (n !== 12) throw new Error(`filtering a paged library showed ${n} cards, expected 12`);
  // …and it went back to the top rather than staying deep in the previous list.
  const label = await moreLabel(window);
  if (label) throw new Error(`a 12-card result still offers more: "${label}"`);
  await window.click('.pf-folderbar [data-folder="Saudi Kings"]');
  await window.waitForTimeout(120);
}

async function testANewQuestionStartsAtTheTop(window) {
  // Page deep into the library, then narrow. A shop that picks a filter is
  // asking something new, and should not land nine hundred cards down — nor
  // should nine hundred cards be PAINTED for a question just asked.
  for (let i = 0; i < 6; i++) { await window.click('[data-act="pf-more"]'); await window.waitForTimeout(60); }
  const deep = await painted(window);
  if (deep < 500) throw new Error(`paging six times only reached ${deep} cards`);
  await window.click('.pf-folderbar [data-cat="Busts"]');   // 600 of the 1200
  await window.waitForTimeout(150);
  const after = await painted(window);
  if (after >= deep) throw new Error(`narrowing kept ${after} cards painted — the page did not reset`);
  if (after > 200) throw new Error(`narrowing left ${after} cards painted, expected one page`);
  await window.click('.pf-folderbar [data-cat="Busts"]');
  await window.waitForTimeout(150);
}

async function testSearchFindsWhatWasNeverPainted(window) {
  await window.evaluate(() => {
    const s = document.getElementById('pfSearch');
    s.value = 'Model 1199';
    s.dispatchEvent(new Event('input'));
  });
  await window.waitForTimeout(300);
  const found = await window.evaluate(() =>
    [...document.querySelectorAll('.pf-card .pf-name')].map((e) => e.textContent.trim()));
  if (!found.includes('Model 1199')) {
    throw new Error(`the last record in the library was not findable: ${found.slice(0, 5)}`);
  }
  await window.evaluate(() => {
    const s = document.getElementById('pfSearch');
    s.value = ''; s.dispatchEvent(new Event('input'));
  });
  await window.waitForTimeout(300);
}

async function testSelectAllShownMeansEveryMatchNotThePage(window) {
  await window.click('[data-act="pf-select-toggle"]');
  await window.waitForSelector('.pf-bulk');
  const paintedNow = await painted(window);
  await window.click('[data-act="pf-pick-all"]');
  await window.waitForTimeout(150);
  const held = await window.evaluate(() =>
    Number((document.querySelector('.pf-bulk-n')?.textContent.match(/\d+/) || [0])[0]));
  if (held !== N) {
    throw new Error(`"select all shown" held ${held} of ${N} — it took the painted page (${paintedNow}), not the match`);
  }
  await window.click('[data-act="pf-select-off"]');
}

async function testTheGalleryIsPagedToo(window) {
  // Every figure there holds a FULL photo, not a 320px preview, so drawing a
  // thousand at once is a thousand images decoded before anything appears.
  await window.evaluate(() => {
    const png = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    for (const r of printFiles) r.userPhoto = png;
    renderPrintFiles();
  });
  await window.click('[data-act="pf-view-gallery"]');
  await window.waitForSelector('.pf-shot');
  const shots = await window.evaluate(() => document.querySelectorAll('.pf-shot').length);
  if (shots >= N) throw new Error(`the gallery painted all ${shots} photos`);
  const label = await moreLabel(window);
  if (!label.includes(String(N))) throw new Error(`the gallery count does not speak for all of it: "${label}"`);
  await window.click('[data-act="pf-more"]');
  await window.waitForTimeout(150);
  const after = await window.evaluate(() => document.querySelectorAll('.pf-shot').length);
  if (after <= shots) throw new Error(`the gallery did not grow: ${after} was ${shots}`);
  await window.click('[data-act="pf-view-library"]');
  await window.waitForSelector('.pf-card');
  // …and coming back starts at the top rather than inheriting the gallery's page.
  const back = await painted(window);
  if (back > 200) throw new Error(`returning to the library painted ${back} cards`);
  await window.evaluate(() => { for (const r of printFiles) r.userPhoto = null; renderPrintFiles(); });
}

async function testTheUnfiledChipActuallyFilters(window) {
  /* It never has. `UNFILED` was `'\u0000unfiled'` written into `data-folder`,
   * and the HTML tokenizer turns U+0000 in an attribute into U+FFFD — so what
   * came back off `dataset` never equalled the sentinel, the filter matched no
   * group, and normalizeFilters quietly reset it. The grid redrew identical to
   * All, so it looked like a chip that simply showed everything. */
  const chip = '.pf-folderbar [data-act="pf-folder"][data-unfiled]';
  const present = await window.evaluate((sel) => !!document.querySelector(sel), chip);
  if (!present) throw new Error('there is no Unfiled chip to press');
  const total = await window.evaluate(() => printFiles.length);
  const ungrouped = await window.evaluate(() => printFiles.filter((r) => !(r.group || r.folder)).length);
  if (ungrouped === total) throw new Error('the seed has nothing grouped, so this proves nothing');
  await window.click(chip);
  await window.waitForTimeout(150);
  // The PAINTED count cannot tell these apart — both are one page. What the
  // filter matched can: the sentinel line says "120 of N".
  const m = (await moreLabel(window)).match(/(\d[\d,]*)\s*$/);
  const matched = m ? Number(m[1].replace(/,/g, '')) : 0;
  if (matched === total) throw new Error(`the Unfiled chip matched the whole library (${matched} of ${total})`);
  if (matched !== ungrouped) throw new Error(`Unfiled matched ${matched}, expected ${ungrouped}`);
  // …and pressing it again clears, rather than sticking.
  await window.click(chip);
  await window.waitForTimeout(150);
  const back = (await moreLabel(window)).match(/(\d[\d,]*)\s*$/);
  if (!back || Number(back[1].replace(/,/g, '')) !== total) {
    throw new Error('pressing Unfiled again did not clear the filter');
  }
}

async function testTheBarsCountFollowsTheFilter(window) {
  // The bar lives outside #pfList, so narrowing the grid used to leave its count
  // speaking for the previous filter — "Select all 1,200 shown" over 12 kings.
  await window.click('[data-act="pf-select-toggle"]');
  await window.waitForSelector('.pf-bulk');
  await window.click('.pf-folderbar [data-folder="Saudi Kings"]');
  await window.waitForTimeout(150);
  const label = await window.evaluate(() =>
    document.querySelector('[data-act="pf-pick-all"]')?.textContent.trim() || '');
  if (/1200|1,200/.test(label)) throw new Error(`the bar still speaks for the old filter: "${label}"`);
  if (!/12\b/.test(label)) throw new Error(`the bar does not say how many the filter matched: "${label}"`);
  await window.click('.pf-folderbar [data-folder="Saudi Kings"]');
  await window.click('[data-act="pf-select-off"]');
  await window.waitForTimeout(100);
}

async function testAChipsNumberIsAPromise(window) {
  /* These counted the whole library while the grid narrows on four axes, so
   * with a category on, the group bar still offered its library-wide total and
   * pressing it showed fewer. A number on a button is a promise about what
   * pressing it gives you. */
  const count = (sel) => window.evaluate((s) => {
    const el = document.querySelector(s);
    return el ? Number((el.textContent.match(/(\d+)\s*$/) || [0, 0])[1]) : -1;
  }, sel);
  const kingsChip = '.pf-folderbar [data-folder="Saudi Kings"]';
  const before = await count(kingsChip);
  if (before !== 12) throw new Error(`the group chip should count 12 kings, said ${before}`);

  // Half the library is Busts; 6 of the 12 kings are.
  await window.click('.pf-folderbar [data-cat="Busts"]');
  await window.waitForTimeout(150);
  const after = await count(kingsChip);
  if (after === before) throw new Error(`the group chip still counts the whole library (${after}) with a category on`);
  const shown = await window.evaluate(async () => {
    const el = document.querySelector('.pf-folderbar [data-folder="Saudi Kings"]');
    // Null when a facet has excluded ITSELF from its own count: every chip but
    // the active one reads 0 and drops out of the bar. Reported rather than
    // thrown from inside evaluate, where it hangs the run instead of failing.
    if (!el) return -1;
    el.click();
    await new Promise((r) => setTimeout(r, 150));
    return document.querySelectorAll('#printfiles-tab .pf-card').length;
  });
  if (shown === -1) throw new Error('the group chip vanished — a facet is counting against its own filter');
  if (shown !== after) throw new Error(`the chip promised ${after} and showed ${shown}`);
  // …and its own axis is NOT excluded from its own count, or every other chip
  // would read 0 the moment one was pressed and the bar would collapse.
  const stillCounts = await count(kingsChip);
  if (stillCounts !== after) throw new Error(`pressing a chip changed its own count to ${stillCounts}`);
  await window.click(kingsChip);
  await window.click('.pf-folderbar [data-cat="Busts"]');
  await window.waitForTimeout(150);
}

async function testArchivedModelsLeaveTheLibrary(window) {
  // A model the Mac archived (archivedAt — by the shop, or because its vault
  // file was trashed elsewhere, #2071) stays in the book but out of the
  // library, as on the Mac. The desktop showed it as a live model.
  await window.evaluate(() => {
    const at = '2026-10-26T09:00:00Z';
    Object.assign(printFiles.find((r) => r.id === 'BIG-7'), { name: 'Archived Zebra', archivedAt: at });
    Object.assign(printFiles.find((r) => r.id === 'BIG-8'), { name: 'Archived Zebra two', archivedAt: at, vaultArchived: true, vaultTrashedAt: at });
    Object.assign(printFiles.find((r) => r.id === 'BIG-9'), { name: 'Trashed Zebra not archived', vaultTrashedAt: at });
    renderPrintFiles();
  });
  const label = await moreLabel(window);
  if (!label.includes(String(N - 2))) throw new Error(`the library still counts archived models: "${label}"`);
  const found = await window.evaluate(async () => {
    const box = document.getElementById('pfSearch');
    box.value = 'Zebra'; box.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise((r) => setTimeout(r, 400));
    return [...document.querySelectorAll('#printfiles-tab .pf-card')].map((c) => c.textContent).join(' | ');
  });
  if (/Archived Zebra/.test(found) || !/Trashed Zebra not archived/.test(found)) throw new Error(`search should find only the live Zebra: ${found}`);
  const archived = await window.evaluate(async () => {
    const chip = document.querySelector('[data-act="pf-archived"]');
    if (!chip) return null;
    const n = chip.textContent.trim();
    chip.click();
    await new Promise((r) => setTimeout(r, 150));
    const shown = [...document.querySelectorAll('#printfiles-tab .pf-card')].map((c) => c.textContent);
    document.querySelector('[data-act="pf-archived"]').click();
    const box = document.getElementById('pfSearch');
    box.value = ''; box.dispatchEvent(new Event('input', { bubbles: true }));
    await new Promise((r) => setTimeout(r, 400));
    return { n, shown };
  });
  if (!archived) throw new Error('no Archived chip while the Mac has archived models');
  if (!/2$/.test(archived.n)) throw new Error(`the Archived chip should count 2: "${archived.n}"`);
  if (archived.shown.length !== 2 || !archived.shown.every((x) => /Archived Zebra/.test(x))) throw new Error(`Archived should show only the two archived models: ${archived.shown.join(' | ')}`);
  const offered = await window.evaluate(() => typeof KhaytLibraryArchive !== 'undefined'
    && KhaytLibraryArchive.pool(printFiles, false).every((r) => !r.archivedAt));
  if (!offered) throw new Error('the shared rule is not loaded in the app');
  // Back to an all-live library for the tests after this one.
  await window.evaluate(() => { for (const r of printFiles) delete r.archivedAt; renderPrintFiles(); });
  if (await window.evaluate(() => !!document.querySelector('[data-act="pf-archived"]'))) throw new Error('the Archived chip stays with nothing archived');
}

async function testPaintingAPageIsFast(window) {
  // The number this exists for. Generous against CI, and still ~20x under what
  // painting every card cost.
  const ms = await window.evaluate(() => {
    const a = performance.now();
    renderPrintFiles();
    return performance.now() - a;
  });
  if (ms > 250) throw new Error(`painting took ${Math.round(ms)} ms at ${N} records — the page is not bounding the work`);
  console.log(`  (render at ${N} records: ${Math.round(ms)} ms)`);
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'printfiles-tab');
  await seed(window, N);

  await testOnlyAPageIsPainted(window);
  await testScrollingGrowsThePageWithoutPressingAnything(window);
  await testTheRestArrivesWhenAskedFor(window);
  await testFiltersNarrowTheWholeLibraryNotThePage(window);
  await testANewQuestionStartsAtTheTop(window);
  await testSearchFindsWhatWasNeverPainted(window);
  await testSelectAllShownMeansEveryMatchNotThePage(window);
  await testTheUnfiledChipActuallyFilters(window);
  await testTheBarsCountFollowsTheFilter(window);
  await testAChipsNumberIsAPromise(window);
  await testTheGalleryIsPagedToo(window);
  await testArchivedModelsLeaveTheLibrary(window);
  await testPaintingAPageIsFast(window);

  console.log('e2e-big-library: ok (a page is painted, the rest on demand, filters and search see all of it, select-all means every match, Mac-archived models leave the library)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
