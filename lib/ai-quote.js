'use strict';
(function () {

/**
 * AI flagship core — quote-from-description (Phase: AI assist).
 * See docs/KHAYT-3.0-AI-SPEC.md.
 *
 * GOVERNING CONTRACT: the AI fills the quote *form*; the existing calculator
 * (`computePartBaseCost`) computes the *price*. This module only turns a model's
 * structured extraction into a calculator `part` + surfaced assumptions. It
 * NEVER invents a price, finalizes a quote, or writes the store.
 *
 * Pure + transport-injected: `createAiQuoteClient({ transport })` takes the model
 * call as a dependency (the Anthropic SDK in the app, a mock in tests), so the
 * whole pipeline is testable with no network and no API key.
 */

/** JSON-schema-ish contract for the model's structured output (physical facts only). */
const EXTRACTION_SCHEMA = {
  type: 'object',
  required: ['qty'],
  properties: {
    qty: { type: 'integer', minimum: 1 },
    materialGuess: { type: 'string' },        // e.g. "PLA", "blue PETG"
    printWeightG: { type: 'number', minimum: 0 },
    printTimeMin: { type: 'number', minimum: 0 },
    dimensionsMm: { type: 'string' },          // optional, free-form
    complexity: { type: 'string', enum: ['low', 'medium', 'high'] },
    assumptions: { type: 'array', items: { type: 'string' } },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
  },
};

/** Validate a model extraction. Returns { ok, errors }. */
function validateDraft(draft) {
  const errors = [];
  if (!draft || typeof draft !== 'object') return { ok: false, errors: ['no draft'] };
  const qty = Number(draft.qty);
  if (!Number.isFinite(qty) || qty < 1) errors.push('qty must be a positive integer');
  if (draft.printWeightG != null && (!Number.isFinite(+draft.printWeightG) || +draft.printWeightG < 0)) errors.push('printWeightG invalid');
  if (draft.printTimeMin != null && (!Number.isFinite(+draft.printTimeMin) || +draft.printTimeMin < 0)) errors.push('printTimeMin invalid');
  if (draft.confidence != null && (+draft.confidence < 0 || +draft.confidence > 1)) errors.push('confidence out of range');
  return { ok: errors.length === 0, errors };
}

/** Fuzzy-match a material guess to a shop inventory item. Returns the item or null. */
function matchMaterial(materialGuess, inventory) {
  const g = String(materialGuess || '').toLowerCase().trim();
  if (!g || !Array.isArray(inventory)) return null;
  const items = inventory.filter((i) => i && (i.material || i.name));
  // 1) exact material code match (PLA, PETG, ABS…)
  let hit = items.find((i) => String(i.material || '').toLowerCase() === g);
  if (hit) return hit;
  // 2) guess contains the material code (e.g. "blue petg" → PETG)
  hit = items.find((i) => i.material && g.includes(String(i.material).toLowerCase()));
  if (hit) return hit;
  // 3) name substring either direction
  hit = items.find((i) => {
    const n = String(i.name || '').toLowerCase();
    return n && (n.includes(g) || g.includes(n));
  });
  return hit || null;
}

/**
 * Turn a validated extraction into a calculator `part` (physical fields), plus
 * the surfaced assumptions. Rate fields come from `defaults` (settings), NEVER
 * from the model. `inventory` is used to bind a real filament + spool cost.
 * @returns {{ part: object, assumptions: string[], unmatchedMaterial: boolean }}
 */
function draftToPart(draft, { inventory = [], defaults = {}, reclaimsTax = false } = {}) {
  const match = matchMaterial(draft.materialGuess, inventory);
  // The price without the tax, for a shop that gets the tax back — see
  // `KhaytSpoolEdit.netCost`. A spool with none recorded costs what it cost.
  const SE = (typeof globalThis !== 'undefined' && globalThis.KhaytSpoolEdit) || null;
  const spoolBasis = (match && SE && typeof SE.netCost === 'function')
    ? SE.netCost(match, !!reclaimsTax)
    : (match ? (+match.cost || 0) : 0);
  const part = {
    qty: Math.max(1, Math.round(+draft.qty || 1)),
    printWeight: Math.max(0, +draft.printWeightG || 0),
    supportWeight: 0,
    printTime: Math.max(0, +draft.printTimeMin || 0),
    // material binding (or fall back to defaults; the owner edits before sending)
    filamentId: match ? match.id : (defaults.filamentId || null),
    spoolCost: match ? (spoolBasis || +defaults.spoolCost || 0) : (+defaults.spoolCost || 0),
    spoolWeight: match ? (+match.spoolWeight || +match.weight || +defaults.spoolWeight || 1000) : (+defaults.spoolWeight || 1000),
    // rate fields are shop defaults, not AI output
    wearRate: +defaults.wearRate || 0,
    powerDraw: +defaults.powerDraw || 0,
    elecRate: +defaults.elecRate || 0,
    prepTime: +defaults.prepTime || 0,
    postTime: +defaults.postTime || 0,
    laborRate: +defaults.laborRate || 0,
    failureRate: +defaults.failureRate || 0,
    extraMaterials: [],
  };
  const assumptions = Array.isArray(draft.assumptions) ? draft.assumptions.slice() : [];
  if (!match && draft.materialGuess) assumptions.push(`Material "${draft.materialGuess}" not matched to inventory — please pick a spool.`);
  return { part, assumptions, unmatchedMaterial: !match && !!draft.materialGuess };
}

/** System prompt fragment listing the shop's materials so guesses map to stock. */
function buildSystemContext(materials) {
  const list = (materials || []).map((m) => m.material || m.name).filter(Boolean);
  return [
    'You estimate 3D-print jobs. Return ONLY physical facts as structured output:',
    'qty, materialGuess, printWeightG, printTimeMin, complexity, assumptions[], confidence.',
    'NEVER return a price — the shop calculator computes that. State every inference in assumptions[].',
    list.length ? `Shop materials: ${list.join(', ')}.` : '',
  ].filter(Boolean).join(' ');
}

/**
 * Create a quote-extraction client. `transport(messages, opts)` performs the
 * model call (Anthropic Messages API in the app; a mock in tests) and must
 * resolve to the structured draft object. Returns { extract }.
 */
function createAiQuoteClient({ transport, model = 'claude-opus-5' } = {}) {
  if (typeof transport !== 'function') throw new Error('transport function required');
  async function extract(request, { materials = [], image = null } = {}) {
    if (!request || !String(request).trim()) throw new Error('empty request');
    const draft = await transport({
      model,
      system: buildSystemContext(materials),
      request: String(request),
      image: image || null,
      schema: EXTRACTION_SCHEMA,
    });
    const { ok, errors } = validateDraft(draft);
    if (!ok) throw new Error('invalid extraction: ' + errors.join('; '));
    return draft;
  }
  return { extract };
}

const api = {
  EXTRACTION_SCHEMA,
  validateDraft,
  matchMaterial,
  draftToPart,
  buildSystemContext,
  createAiQuoteClient,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiQuote = api;

})();
