'use strict';
/**
 * The RULES of the scoped API tokens — which scopes exist, which one a request
 * needs, whether a token holds it, what the owner is shown — apart from the
 * crypto that mints and hashes them (`lib/api-tokens.js`, Node).
 *
 * A module of its own because two apps ask it: the desktop's LAN server, and
 * the native Mac's, which runs this file in JavaScriptCore. JavaScriptCore has
 * no `require('crypto')`, so the Mac mints and hashes in Swift
 * (`ApiTokens.swift`, CryptoKit) to the same format, and asks this file the
 * same questions the desktop asks. Pure: no crypto, no clock.
 */
(function (global) {

// Every capability a token can be granted. Deliberately coarse: one scope per
// collection per direction, so a connector asks for the minimum it needs.
const SCOPES = [
  'orders:read', 'orders:write',
  'clients:read', 'clients:write',
  'inventory:read', 'inventory:write',
  'machines:read',
];

const TOKEN_PREFIX = 'khayt_';

function isValidScope(s) { return SCOPES.includes(s); }

/** Extract a bearer token from an Authorization header, or null. */
function bearerFromHeader(authHeader) {
  const h = String(authHeader || '').trim();
  if (!/^bearer\s+/i.test(h)) return null;
  const tok = h.replace(/^bearer\s+/i, '').trim();
  return tok.startsWith(TOKEN_PREFIX) ? tok : null;
}

/** Does this token record carry the required scope? */
function hasScope(record, scope) {
  return !!(record && Array.isArray(record.scopes) && record.scopes.includes(scope));
}

/**
 * The scope a request requires: collection derived from the path, direction from the
 * method. Returns null for routes that need no scope (public status).
 */
function requiredScope(pathname, method) {
  const p = String(pathname || '');
  const write = ['POST', 'PATCH', 'PUT', 'DELETE'].includes(String(method || '').toUpperCase());
  const seg = (p.split('/').filter(Boolean)[1] || '').toLowerCase(); // /v1/<seg>/...
  const map = {
    orders: 'orders', queue: 'orders',
    clients: 'clients',
    inventory: 'inventory',
    machines: 'machines',
    'waiting-list': 'clients',
  };
  const coll = map[seg];
  if (!coll) return null;
  if (coll === 'machines') return 'machines:read'; // no machine writes over the API
  return `${coll}:${write ? 'write' : 'read'}`;
}

/** Owner-facing view — never exposes the hash. */
function redactTokens(tokens) {
  return (Array.isArray(tokens) ? tokens : []).map(t => ({
    id: t.id, label: t.label, scopes: Array.isArray(t.scopes) ? t.scopes.slice() : [],
    createdAt: t.createdAt || null, lastUsedAt: t.lastUsedAt || null,
  }));
}

const api = { SCOPES, TOKEN_PREFIX, isValidScope, bearerFromHeader, hasScope, requiredScope, redactTokens };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytApiTokenScopes = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
