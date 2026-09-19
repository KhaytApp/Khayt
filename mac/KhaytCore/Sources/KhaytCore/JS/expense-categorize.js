'use strict';
(function () {
/**
 * Smart expense categorization — guess an expense category from its free-text
 * note/vendor using keyword matching (English + common Arabic terms). Pure +
 * deterministic so it's testable and works offline; the renderer can offer the
 * guess as a one-tap suggestion. Returns null when nothing matches confidently.
 */

// category id → trigger substrings (lowercased). Order doesn't matter; the
// category with the most distinct hits wins (ties broken by KEY_ORDER).
const KEYWORDS = {
  filament: ['filament', 'pla', 'petg', 'abs', 'tpu', 'resin', 'spool', 'roll', 'nylon', 'خيط', 'فلمنت', 'بكرة', 'راتنج'],
  electricity: ['electric', 'electricity', 'power', 'kwh', 'utility', 'utilities', 'energy', 'كهرباء', 'فاتورة كهرباء'],
  maintenance: ['repair', 'maintenance', 'nozzle', 'belt', 'service', 'lubricant', 'bearing', 'calibrat', 'صيانة', 'إصلاح', 'فوهة'],
  shipping: ['ship', 'shipping', 'courier', 'delivery', 'postage', 'freight', 'aramex', 'dhl', 'fedex', 'smsa', 'ups', 'شحن', 'توصيل', 'بريد'],
  tools: ['tool', 'tools', 'supply', 'supplies', 'glue', 'tape', 'hardware', 'screw', 'spatula', 'cleaner', 'أدوات', 'لوازم', 'غراء'],
};
const KEY_ORDER = ['filament', 'electricity', 'maintenance', 'shipping', 'tools'];

/**
 * @param {string} text  the expense note / vendor description
 * @returns {string|null} a category id, or null if no confident match
 */
function suggestCategory(text) {
  const s = String(text == null ? '' : text).toLowerCase();
  if (!s.trim()) return null;
  let best = null, bestHits = 0;
  for (const cat of KEY_ORDER) {
    let hits = 0;
    for (const kw of KEYWORDS[cat]) if (s.includes(kw)) hits++;
    if (hits > bestHits) { best = cat; bestHits = hits; }
  }
  return bestHits > 0 ? best : null;
}

const api = { KEYWORDS, suggestCategory };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytExpenseCategorize = api;
})();
