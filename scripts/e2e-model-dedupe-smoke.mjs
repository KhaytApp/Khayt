#!/usr/bin/env node
/**
 * E2E: the library recognises a file the shop already has.
 *
 * The rules are unit-tested. What only a running app can show is that the hash
 * survives the round trip — computed in the main process at import, stored on
 * the record, and compared in a sandboxed renderer that has no crypto of its
 * own — and that the shop is told the difference between "the same file" and
 * "looks like the same part".
 *
 * Requires display (use xvfb-run on Linux CI).
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-dedupe-'));
let electronApp;

const CUBE = ['v 0 0 0', 'v 20 0 0', 'v 20 20 0', 'v 0 20 0',
  'v 0 0 20', 'v 20 0 20', 'v 20 20 20', 'v 0 20 20',
  'f 1 4 3', 'f 1 3 2', 'f 5 6 7', 'f 5 7 8', 'f 1 2 6', 'f 1 6 5',
  'f 2 3 7', 'f 2 7 6', 'f 3 4 8', 'f 3 8 7', 'f 4 1 5', 'f 4 5 8'].join('\n');

/** Import a real file through the real IPC, as a drag-and-drop would. */
async function importFile(window, srcPath, recordId) {
  return window.evaluate(async ([src, id]) => {
    const picked = await window.hubAPI.printLibCopyPath(id, src);
    if (!picked || !picked.ok) throw new Error('copy failed: ' + JSON.stringify(picked));
    return picked;
  }, [srcPath, recordId]);
}

async function testTheMainProcessHashesOnImport(window) {
  const p = path.join(scratch, 'bracket.obj');
  fs.writeFileSync(p, CUBE);
  const picked = await importFile(window, p, 'E2E-DUP-1');
  if (!picked.contentHash) throw new Error('no contentHash came back from the import');
  if (!/^[0-9a-f]{64}$/.test(picked.contentHash)) throw new Error(`not a sha-256: ${picked.contentHash}`);

  // The same bytes at a different path must hash the same — the file's identity
  // is its content, not where it happened to be sitting.
  const p2 = path.join(scratch, 'somewhere-else.obj');
  fs.writeFileSync(p2, CUBE);
  const again = await importFile(window, p2, 'E2E-DUP-2');
  if (again.contentHash !== picked.contentHash) {
    throw new Error('the same bytes hashed differently from a different path');
  }
  // …and a changed file must not.
  const p3 = path.join(scratch, 'different.obj');
  fs.writeFileSync(p3, CUBE + '\nv 1 1 1');
  const other = await importFile(window, p3, 'E2E-DUP-3');
  if (other.contentHash === picked.contentHash) throw new Error('different bytes hashed the same');
  return picked.contentHash;
}

/** The renderer has no crypto — it must still compare hashes fine. */
async function testTheSandboxedRendererCanCompare(window, hash) {
  const r = await window.evaluate((h) => ({
    loaded: typeof KhaytModelIdentity === 'object',
    hashHere: KhaytModelIdentity.contentHash('anything'),
    matched: KhaytModelIdentity.findMatches([{ id: 'x', contentHash: h }], { contentHash: h }).exact.length,
    key: KhaytModelIdentity.geometryKey({ triangleCount: 12, volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } }),
  }), hash);
  if (!r.loaded) throw new Error('the identity module did not load in the renderer');
  if (r.hashHere !== null) throw new Error('the sandboxed renderer should not be able to hash');
  if (r.matched !== 1) throw new Error('the renderer could not match a stored hash');
  if (r.key !== '12:8000:20x20x20') throw new Error(`geometry key was ${r.key}`);
}

async function testAddingATwinWarns(window, hash) {
  await window.evaluate((h) => {
    printFiles.length = 0;
    printFiles.push({
      id: 'E2E-ORIGINAL', name: 'Bracket (March)', originalName: 'bracket.obj',
      createdAt: Date.now() - 86400000, contentHash: h, geometryKey: '12:8000:20x20x20',
      parsed: {}, tags: [], folder: '', setups: [],
    });
    renderPrintFiles();
  }, hash);

  // Import the same bytes again, exactly as ingestPicked would.
  await window.evaluate((h) => {
    printFiles.unshift({
      id: 'E2E-TWIN', name: 'bracket', originalName: 'bracket.obj',
      createdAt: Date.now(), contentHash: h, geometryKey: '12:8000:20x20x20',
      parsed: {}, tags: [], folder: '', setups: [],
    });
    warnIfAlreadyHave(printFiles[0]);
  }, hash);
  await window.waitForSelector('#dupRemove');

  const body = await window.evaluate(() => document.querySelector('.modal-body')?.textContent || '');
  if (!/Bracket \(March\)/.test(body)) throw new Error(`the warning does not name the file we have: ${body}`);
  if (!/byte-for-byte/i.test(body)) throw new Error('the warning does not say the match is exact');

  // Confirming with the box ticked drops the copy, keeps the original.
  await window.click('[data-act="save"]');
  await window.waitForSelector('#dupRemove', { state: 'detached' });
  const ids = await window.evaluate(() => printFiles.map((f) => f.id));
  if (ids.includes('E2E-TWIN')) throw new Error('the duplicate copy was not removed');
  if (!ids.includes('E2E-ORIGINAL')) throw new Error('the ORIGINAL was removed — the history is gone');
}

async function testALookAlikeIsHedged(window) {
  await window.evaluate(() => {
    printFiles.length = 0;
    printFiles.push(
      { id: 'A', name: 'Bracket A', contentHash: 'hashA', geometryKey: '12:8000:20x20x20',
        parsed: {}, tags: [], folder: '', createdAt: Date.now() },
      // Same mesh, different bytes: a re-container, not the same file.
      { id: 'B', name: 'Bracket B', contentHash: 'hashB', geometryKey: '12:8000:20x20x20',
        parsed: {}, tags: [], folder: '', createdAt: Date.now() });
    renderPrintFiles();
  });
  const card = await window.evaluate(() =>
    document.querySelector('.pf-card[data-id="B"]')?.textContent || '');
  if (!/Looks like/i.test(card)) throw new Error(`a geometry match should be hedged: ${card.slice(0, 300)}`);
  if (/Same file/i.test(card)) {
    throw new Error('a geometry match was presented as a certainty — that would merge two customers\' parts');
  }
}

try {
  ({ electronApp } = await launchApp(userData));
  const window = await electronApp.firstWindow();
  window.setDefaultTimeout(120_000);
  await dismissWizard(window);
  await switchTab(window, 'printfiles-tab');

  const hash = await testTheMainProcessHashesOnImport(window);
  await testTheSandboxedRendererCanCompare(window, hash);
  await testAddingATwinWarns(window, hash);
  await testALookAlikeIsHedged(window);

  console.log('e2e-model-dedupe: ok (hashed on import, compared in the sandbox, twin warned, look-alike hedged)');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
  fs.rmSync(scratch, { recursive: true, force: true });
}
