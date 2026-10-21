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
    // Gift cards issued to them (lib/gift-card.js, and a loyalty redemption in
    // lib/loyalty.js — both write `issuedTo` and the name) and their loyalty
    // ledger rows: theirs as much as their orders are.
    const giftCards = cardsOf(clientId, c);
    const loyalty = ledgerOf(clientId, c);
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
      giftCards: giftCards.map(g => ({
        id: g.id, code: g.code, initialBalance: g.initialBalance, balance: g.balance,
        issuedToName: g.issuedToName || '', issuedAt: g.issuedAt || null,
        expiresAt: g.expiresAt || null, source: g.source || null,
      })),
      loyaltyLedger: loyalty.map(r => ({ ...r })),
      counts: { orders: orders.length, intake: intake.length, communications: (client && client.commLog || []).length,
                giftCards: giftCards.length, loyaltyLedger: loyalty.length },
    };
  }

  /** The gift cards issued to this customer. */
  function cardsOf(clientId, c) {
    return (c.giftCards || []).filter(g => g && clientId && g.issuedTo === clientId);
  }

  /** This customer's loyalty-ledger rows. */
  function ledgerOf(clientId, c) {
    return (c.loyaltyLedger || []).filter(r => r && clientId && r.clientId === clientId);
  }

  /**
   * A card with money left on it is money the shop OWES its holder — like an
   * invoiced order, it keeps the name, or the shop cannot say whose it is
   * when they come to spend it. A card spent to nothing is only a record.
   */
  function cardHasBalance(card) {
    const b = Number(card && card.balance);
    return Number.isFinite(b) && b > 0;
  }

  /**
   * Plan an erasure without mutating anything — the caller applies it. Two modes:
   *  - 'unlink' (default): drop the client record + the clientId link, but KEEP the order
   *    rows (the shop has its own financial / ZATCA retention basis).
   *  - 'full': additionally blank the denormalized customer name on those orders and purge
   *    the customer's intake rows + communication log.
   * Returns the affected ids/counts so the UI can state the consequences before confirming.
   */
  /**
   * An issued invoice keeps its buyer. Saudi VAT law has the shop keep every tax
   * invoice as issued, and PDPL lets data be kept where a law requires it, so
   * Full erase blanks the name only on a job lib/record-delete.js would let the
   * shop delete outright (no invoice, no money). Without that module every job
   * keeps its name: an erase that leaves a name behind can be run again, an
   * invoice rewritten cannot be un-rewritten.
   */
  function mustKeepBuyer(order) {
    const R = (typeof globalThis !== 'undefined' && globalThis.KhaytRecordDelete)
      || (typeof require === 'function' ? (() => { try { return require('./record-delete.js'); } catch (_) { return null; } })() : null);
    if (!R || typeof R.canDeleteOrder !== 'function') return true;
    return !R.canDeleteOrder(order).ok;
  }

  function planClientErasure(clientId, collections, mode) {
    const c = collections || {};
    const full = mode === 'full';
    const orders = (c.printLog || []).filter(o => o && o.clientId === clientId);
    const keepNameOrderIds = full ? orders.filter(mustKeepBuyer).map(o => o.id) : orders.map(o => o.id);
    const keep = new Set(keepNameOrderIds);
    const blankNameOrderIds = full ? orders.filter(o => !keep.has(o.id)).map(o => o.id) : [];
    const exp = buildClientDataExport(clientId, c);
    const intakeIds = full ? exp.intakeSubmissions.map(r => r.id).filter(Boolean) : [];
    const intakeHistoryIds = full ? exp.intakeHistory.map(r => r.id).filter(Boolean) : [];
    const cards = full ? cardsOf(clientId, c) : [];
    const unlinkGiftCardIds = cards.filter(g => !cardHasBalance(g)).map(g => g.id).filter(Boolean);
    const keepGiftCardIds = cards.filter(cardHasBalance).map(g => g.id).filter(Boolean);
    const ledgerRows = full ? ledgerOf(clientId, c).length : 0;
    return {
      mode: full ? 'full' : 'unlink',
      clientId,
      orderIds: orders.map(o => o.id),
      blankOrderNames: full,
      // Which of `orderIds` lose the name on a full erase, and which keep it
      // because an invoice or a payment was recorded (mustKeepBuyer).
      blankNameOrderIds,
      keepNameOrderIds,
      purgeIntakeIds: intakeIds,
      purgeIntakeHistoryIds: intakeHistoryIds,
      purgeCommLog: full,
      // A full erase takes the holder off a spent card (`issuedTo` to null,
      // `issuedToName` blank); a card with a balance keeps both.
      unlinkGiftCardIds,
      keepGiftCardIds,
      // And takes the customer's link off their loyalty-ledger rows
      // (`clientId` blank); the points and credit stay, for the shop's sums.
      unlinkLoyaltyLedger: full && ledgerRows > 0,
      counts: {
        orders: orders.length,
        keptNames: full ? keepNameOrderIds.length : 0,
        keptCards: keepGiftCardIds.length,
        loyaltyLedger: ledgerRows,
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
