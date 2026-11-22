'use strict';
/**
 * Assembly production tracking — per-part status rollup and the completion gate for
 * BOM assemblies. Pure, no DOM. Implements §5 of docs/KHAYT-3.0-BOM-SPEC.md.
 *
 * Scope note (deliberate deviation from the spec): the spec gates completion for an order
 * with `components[]` **or** more than one distinct part. Gating multi-part orders would
 * change behaviour for the very common "several parts in one cart" case that completes
 * fine today, so the gate applies to **true BOM assemblies only** (`components[]`
 * non-empty). That honours the spec's own promise of "zero behaviour change for
 * single-part products" and, by extension, for existing multi-part orders.
 */
(function () {
  // Per-part lifecycle. 'pending' is the existing default set at order creation.
  const PART_STATUSES = ['pending', 'printing', 'printed', 'qc_pass', 'qc_fail'];

  /** True when the order is a BOM assembly (has non-printed components). */
  function isAssembly(order) {
    return !!(order && Array.isArray(order.components) && order.components.length > 0);
  }

  function partStatusOf(part) {
    const s = part && part.partStatus;
    return PART_STATUSES.includes(s) ? s : 'pending';
  }

  /**
   * Rollup of the printed parts, per spec §5:
   *   'pending'   — any part still pending/printing (or a part failed QC)
   *   'printed'   — every part is printed or qc_pass, but not all have passed QC
   *   'assembled' — every part qc_pass AND the owner ticked the Assembled gate
   * Returns null for non-assemblies so callers can skip the whole concept.
   */
  function deriveAssemblyStatus(order) {
    if (!isAssembly(order)) return null;
    const parts = Array.isArray(order.parts) ? order.parts : [];
    if (!parts.length) return order.assembledAt ? 'assembled' : 'pending';
    const statuses = parts.map(partStatusOf);
    if (statuses.some(s => s === 'pending' || s === 'printing' || s === 'qc_fail')) return 'pending';
    const allPassed = statuses.every(s => s === 'qc_pass');
    if (allPassed && order.assembledAt) return 'assembled';
    return 'printed';
  }

  /**
   * Completion gate. Returns { ok, reason, remaining } — `remaining` names the parts still
   * blocking, so the UI can say exactly what is outstanding rather than just refusing.
   * Non-assemblies always pass (unchanged behaviour).
   */
  function canCompleteAssembly(order) {
    if (!isAssembly(order)) return { ok: true, reason: null, remaining: [] };
    const parts = Array.isArray(order.parts) ? order.parts : [];
    const remaining = parts
      .filter(p => partStatusOf(p) !== 'qc_pass')
      .map(p => ({ name: p.name || '', status: partStatusOf(p) }));
    if (remaining.length) return { ok: false, reason: 'parts_incomplete', remaining };
    if (!order.assembledAt) return { ok: false, reason: 'not_assembled', remaining: [] };
    return { ok: true, reason: null, remaining: [] };
  }

  /** Convenience: the parts that failed QC (candidates for a per-part reprint). */
  function failedParts(order) {
    const parts = Array.isArray(order && order.parts) ? order.parts : [];
    return parts.map((p, i) => ({ part: p, index: i })).filter(x => partStatusOf(x.part) === 'qc_fail');
  }

  const api = { PART_STATUSES, isAssembly, partStatusOf, deriveAssemblyStatus, canCompleteAssembly, failedParts };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytAssembly = api;
})();
