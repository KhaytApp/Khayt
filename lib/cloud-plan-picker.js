'use strict';
(function () {

/**
 * What each Khayt Cloud plan card offers the person looking at it.
 *
 * The server's catalogue (GET /v1/plans) is the source of truth for which
 * plans exist and what they cost; GET /v1/billing/me says which one this shop
 * is on. This turns the two, plus who is asking, into one action per plan —
 * so the rule is here, tested, and the settings card only draws it.
 *
 * Nothing here charges money. During the beta an upgrade is free and the
 * server records it as a trial with no end; when the beta ends the shop has
 * `graceDays` to start paying or it moves back to the default plan.
 *
 * Actions:
 *   current    this shop's plan
 *   downgrade  back to the default (free) plan — always allowed
 *              (a move to a smaller paid plan is still `upgrade`; isSmaller says
 *              it shrinks the vault)
 *   upgrade    any other plan, free during the beta
 *   soon       upgrades are not open yet (the server says freeUpgrades:false)
 *   paid       this shop pays for its plan; change it where it was bought
 *   none       not the owner, billing off, or nothing known yet
 *
 * PURE: no DOM, no network, no clock.
 */

/**
 * @param {{plans?:Array, defaultPlan?:string, beta?:{freeUpgrades?:boolean}}} catalogue
 * @param {{billingEnabled?:boolean, plan?:string, status?:string, active?:boolean}} billing
 * @param {{owner?:boolean}} who
 * @returns {Array<{name:string, action:string}>} in the catalogue's order
 */
function planActions(catalogue, billing, who) {
  const cat = catalogue || {};
  const b = billing || {};
  const plans = Array.isArray(cat.plans) ? cat.plans.filter((p) => p && typeof p.name === 'string') : [];
  const def = cat.defaultPlan || 'free';
  const known = b.billingEnabled === true && typeof b.plan === 'string';
  const owner = !!(who && who.owner);
  // A shop really paying for a plan (not a beta trial) changes it where it
  // bought it; the server refuses the rest as `paid-plan`, so say so first.
  const paying = known && b.active === true && b.status === 'active' && b.plan !== def;
  const open = !!(cat.beta && cat.beta.freeUpgrades === true);
  return plans.map((p) => {
    if (known && p.name === b.plan) return { name: p.name, action: 'current' };
    if (!known || !owner) return { name: p.name, action: 'none' };
    if (p.name === def) return { name: p.name, action: 'downgrade' };
    if (paying) return { name: p.name, action: 'paid' };
    return { name: p.name, action: open ? 'upgrade' : 'soon' };
  });
}

/**
 * The words for a refused POST /v1/shops/{id}/plan, by the server's `reason`.
 * Spelled out, not built from the reason, so every key is findable by name.
 */
const REFUSAL_KEYS = {
  'owner-only': 'cplan.refused.owner_only',
  'billing-off': 'cplan.refused.billing_off',
  'unknown-plan': 'cplan.refused.unknown_plan',
  'no-account': 'cplan.refused.no_account',
  'paid-plan': 'cplan.refused.paid_plan',
  'upgrades-closed': 'cplan.refused.upgrades_closed',
  'beta-over': 'cplan.refused.beta_over',
};
function refusalKey(reason) {
  return Object.prototype.hasOwnProperty.call(REFUSAL_KEYS, reason) ? REFUSAL_KEYS[reason] : 'cplan.refused.other';
}

/** Bytes as the plan cards say them: 2 GB, 150 GB, 1 TB. Binary units, as the server counts. */
function sizeText(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n <= 0) return '';
  const TB = 1024 ** 4;
  const GB = 1024 ** 3;
  if (n >= TB) return `${+(n / TB).toFixed(1)} TB`;
  return `${+(n / GB).toFixed(n >= 10 * GB ? 0 : 1)} GB`;
}

/**
 * Days between Khayt's email and the deletion of vault files still over a
 * smaller plan's limit (khayt-cloud #143, /terms §4). The app only says it;
 * the server keeps the clock.
 */
const OVER_LIMIT_DELETE_DAYS = 90;

/**
 * Whether moving `from` → `to` gives the vault less room, so the move warns
 * that files over the new limit go read-only and are later deleted. Any move
 * to a smaller plan counts, not only the move back to Free.
 */
function isSmaller(catalogue, from, to) {
  const plans = (catalogue && Array.isArray(catalogue.plans)) ? catalogue.plans : [];
  const room = (name) => {
    const p = plans.find((x) => x && x.name === name);
    const n = Number(p && p.limits && p.limits.maxVaultBytes);
    return Number.isFinite(n) ? n : null;
  };
  const a = room(from);
  const b = room(to);
  return a !== null && b !== null && b < a;
}

const api = { planActions, refusalKey, REFUSAL_KEYS, sizeText, isSmaller, OVER_LIMIT_DELETE_DAYS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytCloudPlanPicker = api;

})();
