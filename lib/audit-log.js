'use strict';

/**
 * Activity log / audit trail core — a pure, append-only, hash-chained record of
 * who-did-what. See docs/KHAYT-3.0-AUDIT-SPEC.md.
 *
 * This module is intentionally PURE: data in → data out. It uses only the
 * built-in `crypto` module (no fs, no Electron, no renderer imports) so it can
 * be unit-tested headless and reused on either side of the sync boundary.
 *
 * Tamper-evidence (spec §5): each entry carries
 *   - `hashPrev`: the previous entry's `hash` ("" for the genesis entry)
 *   - `hash`:     SHA-256 over a canonical serialization of the entry with
 *                 `hash` itself excluded (so it covers `hashPrev`)
 * Editing, reordering, or dropping any entry breaks the chain at that point,
 * which `verifyChain` detects. This is tamper-EVIDENT, not tamper-proof — a
 * local attacker with write access can recompute the whole chain.
 *
 * Privacy rule (spec §4): `changes` records field NAMES, never secret VALUES.
 * `redactChanges` replaces values of sensitive fields with a marker. The
 * default denylist mirrors the export-redaction field set in
 * lib/store.js (pin/token/secret/apiKey/password/csid/pcsid).
 */
const crypto = require('crypto');

/** Marker substituted for redacted secret/PII values. */
const REDACTED = '[redacted]';

/**
 * Default denied field-name substrings (case-insensitive). Mirrors the
 * export-redaction set: apiKey, smtpPassword, botToken, webhook secret, ZATCA
 * csid/pcsid, LAN pin/token, etc. — generalized to substrings so new secret
 * fields are caught by name.
 */
const DEFAULT_DENY_KEYS = Object.freeze([
  'pin', 'token', 'secret', 'apikey', 'password', 'csid', 'pcsid',
]);

/**
 * Stable, key-sorted JSON serialization. Object keys are emitted in sorted
 * order at every level so the hash is independent of property insertion order.
 * @param {*} value
 * @returns {string}
 */
function canonicalize(value) {
  return JSON.stringify(sortDeep(value));
}

function sortDeep(value) {
  if (Array.isArray(value)) return value.map(sortDeep);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) {
      const v = value[key];
      if (v === undefined) continue; // JSON would drop these anyway; be explicit
      out[key] = sortDeep(v);
    }
    return out;
  }
  return value;
}

/** SHA-256 hex of a string. */
function sha256Hex(str) {
  return crypto.createHash('sha256').update(str, 'utf8').digest('hex');
}

/**
 * True if `fieldName` matches any deny-key (case-insensitive substring).
 * @param {string} fieldName
 * @param {string[]} denyKeys
 * @returns {boolean}
 */
function isDeniedField(fieldName, denyKeys) {
  const lower = String(fieldName).toLowerCase();
  return denyKeys.some((k) => lower.includes(String(k).toLowerCase()));
}

/**
 * Redact sensitive field VALUES while preserving field NAMES (spec §4).
 * Accepts either the array form `[{field, from?, to?}]` or a plain object map
 * `{field: value}` and returns the same shape with denied values replaced by
 * the REDACTED marker. Non-denied values pass through untouched. Pure: never
 * mutates its input.
 *
 * @param {Array<object>|object|null|undefined} changes
 * @param {string[]} [denyKeys] - defaults to DEFAULT_DENY_KEYS
 * @returns {Array<object>|object} redacted copy (same shape as input)
 */
function redactChanges(changes, denyKeys = DEFAULT_DENY_KEYS) {
  const deny = Array.isArray(denyKeys) && denyKeys.length ? denyKeys : DEFAULT_DENY_KEYS;

  if (Array.isArray(changes)) {
    return changes.map((c) => {
      if (!c || typeof c !== 'object') return c;
      if (!isDeniedField(c.field, deny)) return { ...c };
      const out = { ...c };
      if ('from' in out) out.from = REDACTED;
      if ('to' in out) out.to = REDACTED;
      out.redacted = true;
      return out;
    });
  }

  if (changes && typeof changes === 'object') {
    const out = {};
    for (const [field, value] of Object.entries(changes)) {
      out[field] = isDeniedField(field, deny) ? REDACTED : value;
    }
    return out;
  }

  return changes;
}

/**
 * Normalize the value of `seq` for serialization. Returns the number when a
 * caller supplied it, or undefined to omit it from the entry.
 */
function normalizeSeq(seq) {
  if (seq === undefined || seq === null) return undefined;
  return seq;
}

/**
 * Compute a normalized, hash-stamped entry from a raw entry + the previous
 * entry's hash. The returned entry is a fresh object; the input is not mutated.
 *
 * `hash = sha256(canonical(everything-except-hash, with hashPrev folded in))`.
 *
 * @param {string} prevHash - previous entry's `hash`; "" for the genesis entry
 * @param {object} entry - raw entry (actor/action/entity/entityId/changes/…)
 * @returns {{seq?:number, ts:string, actor:*, action:string, entity:*,
 *            entityId:*, changes:*, hashPrev:string, hash:string}}
 */
function appendEntry(prevHash, entry) {
  const src = entry || {};
  const hashPrev = prevHash == null ? '' : String(prevHash);

  // Build the canonical entry (everything except `hash`). Order here does not
  // matter — canonicalize() sorts keys — but we list the known fields so the
  // shape is explicit and stable.
  const normalized = {
    seq: normalizeSeq(src.seq),
    ts: src.ts == null ? '' : String(src.ts),
    actor: src.actor === undefined ? null : src.actor,
    action: src.action == null ? '' : String(src.action),
    entity: src.entity === undefined ? null : src.entity,
    entityId: src.entityId === undefined ? null : src.entityId,
    changes: src.changes === undefined ? null : src.changes,
    hashPrev,
  };

  const hash = sha256Hex(canonicalize(normalized));

  const result = { ...normalized, hash };
  if (result.seq === undefined) delete result.seq;
  return result;
}

/**
 * Fold a batch of raw entries onto an existing chain, assigning `seq` and
 * linking `hashPrev`/`hash` for each. Pure: returns a NEW array; neither input
 * array nor its entries are mutated.
 *
 * @param {Array<object>} entries - existing chain (may be empty)
 * @param {Array<object>} newEntries - raw entries to append, in order
 * @param {number} [startSeq] - seq for the first new entry; defaults to
 *   (last existing seq) + 1, or 1 when the chain is empty
 * @returns {Array<object>} the new full chain
 */
function appendAll(entries, newEntries, startSeq) {
  const base = Array.isArray(entries) ? entries.slice() : [];
  const additions = Array.isArray(newEntries) ? newEntries : [];

  let prevHash = base.length ? base[base.length - 1].hash : '';
  let seq = startSeq;
  if (seq === undefined || seq === null) {
    const lastSeq = base.length ? base[base.length - 1].seq : 0;
    seq = (typeof lastSeq === 'number' ? lastSeq : 0) + 1;
  }

  for (const raw of additions) {
    const stamped = appendEntry(prevHash, { ...raw, seq });
    base.push(stamped);
    prevHash = stamped.hash;
    seq += 1;
  }

  return base;
}

/**
 * Walk the chain recomputing each hash and checking the `hashPrev` link.
 *
 * @param {Array<object>} entries
 * @returns {{ok: boolean, brokenAt: number|null}} `brokenAt` is the index of
 *   the first entry whose recomputed `hash` or `hashPrev` link is wrong; null
 *   when the chain is intact (including the empty chain).
 */
function verifyChain(entries) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return { ok: true, brokenAt: null };
  }

  let prevHash = '';
  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i] || {};

    // The link to the previous entry must match.
    if ((entry.hashPrev == null ? '' : String(entry.hashPrev)) !== prevHash) {
      return { ok: false, brokenAt: i };
    }

    // Recompute the hash over the entry's content (excluding `hash`).
    const recomputed = appendEntry(prevHash, entry);
    if (recomputed.hash !== entry.hash) {
      return { ok: false, brokenAt: i };
    }

    prevHash = entry.hash;
  }

  return { ok: true, brokenAt: null };
}

/**
 * Map a single Phase 0 collection name + record id into the raw audit fields
 * for a given action.
 */
function stampItemToEntry(item, action, ctx) {
  const it = item || {};
  return {
    ts: ctx && ctx.ts != null ? ctx.ts : '',
    actor: ctx ? ctx.actor : null,
    action,
    entity: it.collection,
    entityId: it.id,
    changes: it.changes !== undefined ? it.changes : null,
  };
}

/**
 * Map a Phase 0 stamp summary into raw audit entries (NOT yet chained — pass
 * the result through `appendAll`). Summary shape (Phase 0):
 *   { created:[{collection,id}], changed:[...], deleted:[...] }
 *
 * @param {{created?:Array, changed?:Array, deleted?:Array}} summary
 * @param {{actor?:*, ts?:string}} [ctx]
 * @returns {Array<object>} raw entries with action create|update|delete
 */
function entriesFromStampSummary(summary, ctx) {
  const s = summary || {};
  const out = [];

  for (const item of Array.isArray(s.created) ? s.created : []) {
    out.push(stampItemToEntry(item, 'create', ctx));
  }
  for (const item of Array.isArray(s.changed) ? s.changed : []) {
    out.push(stampItemToEntry(item, 'update', ctx));
  }
  for (const item of Array.isArray(s.deleted) ? s.deleted : []) {
    out.push(stampItemToEntry(item, 'delete', ctx));
  }

  return out;
}

module.exports = {
  REDACTED,
  DEFAULT_DENY_KEYS,
  appendEntry,
  appendAll,
  verifyChain,
  entriesFromStampSummary,
  redactChanges,
  // low-level (exposed for tests / reuse)
  canonicalize,
  isDeniedField,
};
