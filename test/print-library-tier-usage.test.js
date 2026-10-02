'use strict';

/**
 * Freeing space never moves a model an unfinished job needs, and "unused"
 * counts from the import, the last print and the last job, not just the
 * copied file's date. The Mac's CloudLibrary.usage cases (#1706).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const PLT = require('../lib/print-library-tier.js');
const { itemDirName } = require('../lib/print-library-location.js');

const DAY = 86400000;
const now = Date.parse('2026-10-02T12:00:00Z');
const old = now - 400 * DAY;
const file = (id, extra) => ({ id, filename: 'model.stl', size: 50 * 1024 * 1024, mtimeMs: old, ...extra });

test('usage reads the record and the jobs that name the model', () => {
  const u = PLT.usageFromBook({
    itemDirName,
    printFiles: [
      { id: 'PF-a', createdAt: '2026-09-20T10:00:00Z' },            // imported last month, file copied from 2024
      { id: 'PF-b', createdAt: '2024-01-01T00:00:00Z', lastPrinted: '2026-09-30' },
      { id: 'PF-c', createdAt: '2024-01-01T00:00:00Z' },
    ],
    orders: [
      { id: 'O1', status: 'printing', date: '2025-01-01', parts: [{ printFileId: 'PF-c' }, { printFileId: 'PF-c' }] },
      { id: 'O2', status: 'delivered', date: '2026-09-28', completedAt: '2026-09-29T09:00:00Z', parts: [{ printFileId: 'PF-d' }] },
      { id: 'O3', status: 'cancelled', parts: [{ printFileId: 'PF-e' }] },
      { id: 'O4', status: 'completed', parts: [{}] },
    ],
  });
  assert.equal(u['PF-a'].lastUsedMs, Date.parse('2026-09-20T10:00:00Z'));
  assert.equal(u['PF-b'].lastUsedMs, Date.parse('2026-09-30'));
  assert.equal(u['PF-c'].inUse, true, 'a job still printing needs it');
  assert.equal(u['PF-d'].inUse, false);
  assert.equal(u['PF-d'].lastUsedMs, Date.parse('2026-09-29T09:00:00Z'), 'the later of date and completion');
  assert.equal(u['PF-e'].inUse, false, 'a cancelled job needs nothing');
});

test('the plan keeps recently imported, recently printed and in-use models', () => {
  const usage = PLT.usageFromBook({
    itemDirName,
    printFiles: [{ id: 'PF-a', createdAt: '2026-09-20T10:00:00Z' }, { id: 'PF-z', createdAt: '2024-01-01T00:00:00Z' }],
    orders: [{ status: 'queued', parts: [{ printFileId: 'PF-q' }] }],
  });
  const files = PLT.annotate([file('PF-a'), file('PF-q'), file('PF-z')], usage);
  const p = PLT.plan(files, { enabled: true, keepDays: 90, minBytes: 1 }, now);
  assert.deepEqual(p.candidates.map((f) => f.id), ['PF-z'], 'only the genuinely unused one moves');
  assert.equal(p.skipped['in-use'], 1);
  assert.equal(p.skipped['too-recent'], 1);
  // Without the book it is the old behaviour: the copied file's date alone.
  assert.equal(PLT.plan([file('PF-a'), file('PF-q')], { enabled: true, keepDays: 90, minBytes: 1 }, now).candidates.length, 2);
});

test('both desktop sweeps plan from the annotated listing', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.equal((src.match(/PLT\.plan\(await printLibFilesWithUsage\(\)|const files = await printLibFilesWithUsage\(\);/g) || []).length, 2);
  assert.doesNotMatch(src, /PLT\.plan\(await printLibAllFiles\(\)/);
});
