'use strict';
(function () {

/**
 * AI consent + disclosure — what each AI feature actually sends off this device,
 * and which of them the owner has agreed to.
 *
 * WHY THIS EXISTS: AI was one global `settings.ai.enabled` toggle labelled
 * "AI quote". It gated four features that transmit very different things — and
 * the privacy screen told the owner "Customer data stays on this machine",
 * which stopped being true the moment reply drafting shipped, because
 * buildReplyRequest() sends `Customer name: …` to Anthropic.
 *
 * So the toggle is now per feature, and the disclosure is derived from this
 * table rather than written by hand next to the checkbox — a new AI feature has
 * to add a row here, and the test asserts the row matches what the feature's
 * request builder actually sends.
 *
 * Pure (no DOM, no network, no globals) so all of it is unit-testable.
 */

/**
 * Sensitivity of what leaves the device. These are ordered: 'customer' is the
 * only class that carries a third party's personal data, and is therefore the
 * only one that needs fresh consent from an owner who had the old global
 * toggle on.
 *
 *   own      — only what the owner typed, plus their own shop's material names.
 *   business — the shop's own commercial figures (prices, margins, revenue,
 *              stock, project names). Sensitive to the owner, but not another
 *              person's data.
 *   customer — a customer's personal data. PDPL-relevant.
 */
const DATA_CLASS = { OWN: 'own', BUSINESS: 'business', CUSTOMER: 'customer' };

/**
 * One row per AI feature. `sends` is the plain-language field list shown in
 * Settings; it must stay in step with the matching request builder:
 *
 *   quote     → lib/ai-quote.js  buildSystemContext + the owner's description
 *   price     → lib/ai-price.js  buildPriceRequest
 *   reply     → lib/ai-reply.js  buildReplyRequest
 *   assistant → lib/ai-assistant.js buildShopContext + buildAssistantRequest
 */
const AI_FEATURES = {
  quote: {
    id: 'quote',
    labelKey: 'set.ai_feat_quote',
    sendsKey: 'set.ai_data_quote',
    dataClass: DATA_CLASS.OWN,
    sends: ['the description you type', 'your material names', 'a reference photo if you attach one'],
  },
  price: {
    id: 'price',
    labelKey: 'set.ai_feat_price',
    sendsKey: 'set.ai_data_price',
    dataClass: DATA_CLASS.BUSINESS,
    sends: ['project names, prices and margins from up to 6 past jobs', 'the new job\'s material, weight, hours and cost'],
  },
  reply: {
    id: 'reply',
    labelKey: 'set.ai_feat_reply',
    sendsKey: 'set.ai_data_reply',
    dataClass: DATA_CLASS.CUSTOMER,
    sends: ['the customer\'s name', 'order reference, project, status and due date', 'amount and outstanding balance'],
  },
  assistant: {
    id: 'assistant',
    labelKey: 'set.ai_feat_assistant',
    sendsKey: 'set.ai_data_assistant',
    dataClass: DATA_CLASS.BUSINESS,
    sends: ['order and client counts (not names)', 'revenue, outstanding and overdue totals', 'overdue project names, top materials and low stock'],
  },
};

/** Feature ids whose payload contains another person's personal data. */
function customerDataFeatures() {
  return Object.keys(AI_FEATURES).filter((id) => AI_FEATURES[id].dataClass === DATA_CLASS.CUSTOMER);
}

/**
 * Upgrade path for an owner who only ever saw the single "AI quote" toggle.
 *
 * That toggle cannot stand as consent to send a customer's name to a third
 * party — it did not say so, and at the time it was written it was not true.
 * So features that transmit only the owner's own input or their own business
 * figures inherit the old setting, and customer-data features start OFF until
 * the owner ticks them having read what they send.
 *
 * Idempotent: once `features` exists this returns it untouched, so re-running
 * on an already-migrated store cannot silently re-disable anything the owner
 * has since turned on.
 *
 * @returns {{features: object, reconsentRequired: string[]}}
 */
function migrateConsent(ai) {
  const cfg = ai || {};
  if (cfg.features && typeof cfg.features === 'object') {
    return { features: cfg.features, reconsentRequired: [] };
  }
  const wasOn = !!cfg.enabled;
  const features = {};
  const reconsentRequired = [];
  for (const [id, spec] of Object.entries(AI_FEATURES)) {
    if (spec.dataClass === DATA_CLASS.CUSTOMER) {
      features[id] = false;
      // Only worth telling the owner something changed if it was working before.
      if (wasOn) reconsentRequired.push(id);
    } else {
      features[id] = wasOn;
    }
  }
  return { features, reconsentRequired };
}

/**
 * Whether a given AI feature may run. Requires BOTH the master switch and that
 * feature's own consent — the master switch alone is not enough, so revoking it
 * disables everything without losing the per-feature choices underneath.
 */
function isFeatureEnabled(ai, id) {
  const cfg = ai || {};
  if (!cfg.enabled) return false;
  if (!Object.prototype.hasOwnProperty.call(AI_FEATURES, id)) return false;
  const { features } = migrateConsent(cfg);
  return features[id] === true;
}

/**
 * Feature ids that are enabled AND transmit customer personal data. The privacy
 * screen uses this to keep its "customer data stays on this machine" claim
 * honest: non-empty means the claim needs qualifying.
 */
function activeCustomerDataFeatures(ai) {
  return customerDataFeatures().filter((id) => isFeatureEnabled(ai, id));
}

/** True when the privacy screen's on-device claim needs a caveat. */
function transmitsCustomerData(ai) {
  return activeCustomerDataFeatures(ai).length > 0;
}

const api = {
  DATA_CLASS,
  AI_FEATURES,
  customerDataFeatures,
  migrateConsent,
  isFeatureEnabled,
  activeCustomerDataFeatures,
  transmitsCustomerData,
};

// Dual export: CommonJS (node tests + main process) and global (renderer script tag).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiPrivacy = api;

})();
