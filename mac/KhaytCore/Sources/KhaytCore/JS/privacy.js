'use strict';
/**
 * Privacy / PDPL data-subject helpers — pure, no DOM, shared by the renderer (client
 * editor, retention sweep) and the LAN intake handler (consent records).
 *
 * See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md. Engineering posture only — the legal
 * artefacts (DPA, sub-processor register, breach runbook) live outside the code.
 *
 * Governing principle: PII stays on the shop's own device. These helpers give the owner
 * the three data-subject levers — access (export), rectification (existing editor), and
 * erasure — plus consent capture at the one place a customer submits their own data.
 */
(function () {
  // Bump when the intake notice text changes, so stored consents remain auditable
  // against the exact wording the customer saw.
  const CONSENT_VERSION = 1;

  const NOTICE = {
    en: 'I agree that {shop} may store my contact details to process this request.',
    ar: 'أوافق على أن يحتفظ {shop} ببيانات الاتصال الخاصة بي لمعالجة هذا الطلب.',
  };

  /** The consent notice text for a shop + language, with {shop} interpolated. */
  function consentNoticeText(shopName, lang) {
    const tpl = NOTICE[lang === 'ar' ? 'ar' : 'en'];
    return tpl.replace('{shop}', String(shopName || 'this shop'));
  }

  /**
   * An immutable record of a customer's consent at submission time. Returns null when
   * consent was not given, so callers can reject the submission.
   */
  function consentRecord(agreed, shopName, lang, nowIso) {
    if (!agreed) return null;
    return {
      agreed: true,
      at: nowIso || new Date().toISOString(),
      version: CONSENT_VERSION,
      text: consentNoticeText(shopName, lang),
    };
  }

  /**
   * DSAR / portability: everything Khayt holds about one customer, machine-readable.
   * Never includes shop settings or secrets — only this data subject's records.
   */
  function buildClientDataExport(clientId, collections, nowIso) {
    const c = collections || {};
    const client = (c.clients || []).find(x => x && x.id === clientId) || null;
    const orders = (c.printLog || []).filter(o => o && o.clientId === clientId).map(o => ({
      id: o.id, date: o.date, project: o.project, status: o.status,
      price: o.price, currency: o.currency || null,
      deliveredAt: o.deliveredAt || null, notes: o.notes || '',
      deliveryAddress: o.deliveryAddress || null,
      trackingNumber: o.trackingNumber || null, carrier: o.carrier || null,
    }));
    // Intake rows are matched by the identity the customer submitted, since a waiting-list
    // row may pre-date the client record (no clientId yet).
    const eq = (a, b) => !!a && !!b && String(a).trim().toLowerCase() === String(b).trim().toLowerCase();
    const matchesSubject = (r) => {
      if (!r) return false;
      // An explicit link is authoritative in BOTH directions. A row belonging to another
      // client is never this subject's, however similar its contact details look — the
      // old code only returned true on a match and then fell through to fuzzy matching,
      // which disclosed (and, on erasure, destroyed) another subject's records.
      if (r.clientId) return r.clientId === clientId;
      if (!client) return false;
      // Unlinked rows: strong identifiers only. NEVER match on name alone — two customers
      // can share a name, and a false positive here is an unlawful disclosure on export
      // and an unlawful deletion on erasure. Under-matching is the safe failure direction:
      // the owner can still find a stray row by hand, but cannot un-disclose or un-delete.
      return eq(r.email, client.email) || eq(r.phone, client.phone);
    };
    const intake = (c.waitingList || []).filter(matchesSubject);
    const intakeHistory = (c.waitingListHistory || []).filter(matchesSubject);
    return {
      exportedAt: nowIso || new Date().toISOString(),
      subject: client ? {
        id: client.id, nameEn: client.nameEn || '', nameAr: client.nameAr || '',
        phone: client.phone || '', email: client.email || '',
        addresses: Array.isArray(client.addresses) ? client.addresses.map(a => ({ ...a })) : [],
        cr: client.cr || '', vat: client.vat || '',
        createdAt: client.createdAt || null,
      } : null,
      communications: Array.isArray(client && client.commLog) ? client.commLog.map(l => ({ ...l })) : [],
      orders,
      intakeSubmissions: intake.map(r => ({ ...r })),
      intakeHistory: intakeHistory.map(r => ({ ...r })),
      counts: { orders: orders.length, intake: intake.length, communications: (client && client.commLog || []).length },
    };
  }

  /**
   * Plan an erasure without mutating anything — the caller applies it. Two modes:
   *  - 'unlink' (default): drop the client record + the clientId link, but KEEP the order
   *    rows (the shop has its own financial / ZATCA retention basis).
   *  - 'full': additionally blank the denormalized customer name on those orders and purge
   *    the customer's intake rows + communication log.
   * Returns the affected ids/counts so the UI can state the consequences before confirming.
   */
  function planClientErasure(clientId, collections, mode) {
    const c = collections || {};
    const full = mode === 'full';
    const orders = (c.printLog || []).filter(o => o && o.clientId === clientId);
    const exp = buildClientDataExport(clientId, c);
    const intakeIds = full ? exp.intakeSubmissions.map(r => r.id).filter(Boolean) : [];
    const intakeHistoryIds = full ? exp.intakeHistory.map(r => r.id).filter(Boolean) : [];
    return {
      mode: full ? 'full' : 'unlink',
      clientId,
      orderIds: orders.map(o => o.id),
      blankOrderNames: full,
      purgeIntakeIds: intakeIds,
      purgeIntakeHistoryIds: intakeHistoryIds,
      purgeCommLog: full,
      counts: {
        orders: orders.length,
        intake: intakeIds.length + intakeHistoryIds.length,
        communications: full ? exp.counts.communications : 0,
      },
    };
  }

  /**
   * Retention: intake rows older than `months` that are no longer active leads.
   * Anonymizing (rather than deleting) keeps the operational record while dropping PII.
   */
  function selectStaleIntakeRows(rows, months, nowMs) {
    const list = Array.isArray(rows) ? rows : [];
    const m = Number(months);
    if (!Number.isFinite(m) || m <= 0) return [];
    const cutoff = (typeof nowMs === 'number' ? nowMs : Date.now()) - m * 30 * 86400000;
    return list.filter(r => {
      if (!r) return false;
      const t = Date.parse(r.at || r.date || r.createdAt || '');
      if (!Number.isFinite(t)) return false;
      return t < cutoff;
    });
  }

  /** Strip PII from an intake row in place-safe fashion (returns a new row). */
  function anonymizeIntakeRow(row) {
    if (!row) return row;
    const out = { ...row };
    out.name = '[erased]';
    delete out.email;
    delete out.phone;
    out.anonymizedAt = new Date().toISOString();
    return out;
  }

  const api = {
    CONSENT_VERSION,
    consentNoticeText,
    consentRecord,
    buildClientDataExport,
    planClientErasure,
    selectStaleIntakeRows,
    anonymizeIntakeRow,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPrivacy = api;
})();
