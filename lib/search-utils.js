'use strict';

/**
 * Score how well `query` matches `haystack` (higher = better, 0 = no match).
 * @param {string} haystack
 * @param {string} query
 */
function searchScore(haystack, query) {
  const h = String(haystack || '').toLowerCase();
  const q = String(query || '').toLowerCase().trim();
  if (!q || !h) return 0;
  if (h === q) return 200;
  if (h.startsWith(q)) return 150;
  if (h.includes(q)) return 120;

  const tokens = q.split(/\s+/).filter(Boolean);
  if (tokens.length > 1 && tokens.every((tok) => h.includes(tok))) return 80;

  let hi = 0;
  for (let i = 0; i < q.length; i++) {
    const idx = h.indexOf(q[i], hi);
    if (idx === -1) return 0;
    hi = idx + 1;
  }
  return 40;
}

/**
 * @template T
 * @param {T[]} items
 * @param {string} query
 * @param {(item: T) => string} getHaystack
 * @param {number} [limit]
 */
function rankByQuery(items, query, getHaystack, limit = 6) {
  const q = String(query || '').trim();
  if (!q) return [];
  return items
    .map((item) => ({ item, score: searchScore(getHaystack(item), q) }))
    .filter((row) => row.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map((row) => row.item);
}

module.exports = { searchScore, rankByQuery };
