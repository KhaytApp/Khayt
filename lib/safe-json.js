/**
 * Parse JSON and strip __proto__ / constructor keys (prototype pollution).
 * Throws on invalid JSON (same as JSON.parse).
 */
function safeJsonParse(text) {
  return JSON.parse(text, (key, value) => {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') return undefined;
    return value;
  });
}

module.exports = { safeJsonParse };
