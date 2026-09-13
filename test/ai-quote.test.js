/**
 * AI flagship core tests. See docs/KHAYT-3.0-AI-SPEC.md.
 * Proves the contract end-to-end with a MOCKED model (no network, no key):
 * extraction -> draftToPart -> the REAL calculator computes the price.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const ai = require('../lib/ai-quote.js');

const INVENTORY = [
  { id: 'f-pla', material: 'PLA', name: 'PLA Black', cost: 50, spoolWeight: 1000 },
  { id: 'f-petg', material: 'PETG', name: 'PETG Blue', cost: 80, spoolWeight: 1000 },
];

test('validateDraft accepts a good draft, rejects bad ones', () => {
  assert.equal(ai.validateDraft({ qty: 5 }).ok, true);
  assert.equal(ai.validateDraft({ qty: 0 }).ok, false);
  assert.equal(ai.validateDraft({ qty: 2, printWeightG: -1 }).ok, false);
  assert.equal(ai.validateDraft(null).ok, false);
});

test('matchMaterial binds a guess to a real inventory item (fuzzy)', () => {
  assert.equal(ai.matchMaterial('PLA', INVENTORY).id, 'f-pla');
  assert.equal(ai.matchMaterial('blue petg', INVENTORY).id, 'f-petg');
  assert.equal(ai.matchMaterial('nylon', INVENTORY), null);
});

test('draftToPart builds a calculator part; rates come from defaults, not the model', () => {
  const draft = { qty: 10, materialGuess: 'PLA', printWeightG: 40, printTimeMin: 90, assumptions: ['~40g at 0.2mm'] };
  const { part, assumptions, unmatchedMaterial } = ai.draftToPart(draft, {
    inventory: INVENTORY,
    defaults: { laborRate: 30, elecRate: 0.18, powerDraw: 150, prepTime: 5 },
  });
  assert.equal(part.qty, 10);
  assert.equal(part.printWeight, 40);
  // HOURS. The model answers in minutes (`printTimeMin`) and this converts,
  // because `printTime` means hours on every other part in the codebase — the
  // calculator, the store, the invoice and both editors.
  assert.equal(part.printTime, 1.5, 'printTime is hours, not the model\'s minutes');
  assert.equal(part.filamentId, 'f-pla');
  assert.equal(part.spoolCost, 50);
  assert.equal(part.laborRate, 30, 'rate fields come from shop defaults');
  assert.equal(unmatchedMaterial, false);
  assert.ok(assumptions.includes('~40g at 0.2mm'), 'model assumptions surfaced for review');
});

test('unmatched material is flagged with a review assumption (no silent guess)', () => {
  const { unmatchedMaterial, assumptions } = ai.draftToPart({ qty: 1, materialGuess: 'carbon nylon' }, { inventory: INVENTORY });
  assert.equal(unmatchedMaterial, true);
  assert.ok(assumptions.some((a) => /not matched/i.test(a)));
});

test('CONTRACT: mock model → draftToPart → the real calculator computes the price', () => {
  // The calculator is the price authority; AI only fills the form.
  global.inventory = INVENTORY;
  global.settings = {};
  require('../lib/calculator-cost.js'); // global.computePartBaseCost

  const transport = async () => ({ qty: 1, materialGuess: 'PLA', printWeightG: 100, printTimeMin: 60, confidence: 0.8 });
  return ai.createAiQuoteClient({ transport }).extract('100g PLA bracket', { materials: INVENTORY }).then((draft) => {
    const { part } = ai.draftToPart(draft, {
      inventory: INVENTORY,
      defaults: { laborRate: 0, elecRate: 0, powerDraw: 0 },
    });
    const cost = global.computePartBaseCost(part);
    // material only: spoolCost 50 / spoolWeight 1000 * 100g = 5.00 (rates zeroed)
    assert.ok(Math.abs(cost - 5) < 1e-6, `deterministic calculator price (got ${cost})`);
  });
});

test('extract rejects an invalid model response (guardrail)', async () => {
  const transport = async () => ({ qty: 0 }); // model returned junk
  await assert.rejects(
    () => ai.createAiQuoteClient({ transport }).extract('something', {}),
    /invalid extraction/,
  );
});

test('extract rejects an empty request', async () => {
  const transport = async () => ({ qty: 1 });
  await assert.rejects(() => ai.createAiQuoteClient({ transport }).extract('   ', {}), /empty request/);
});

test('buildSystemContext lists shop materials and forbids prices', () => {
  const ctx = ai.buildSystemContext(INVENTORY);
  assert.ok(/PLA/.test(ctx) && /PETG/.test(ctx));
  assert.ok(/NEVER return a price/i.test(ctx));
});
