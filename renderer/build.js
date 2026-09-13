/**
 * Calculator / build workspace: quote cart, presets, filament picker, quote templates.
 */
const CURRENT_BUILD_KEY = 'hub_current_build_v1';

// In-memory only — the current quote workspace
let currentBuild = [];
let currentBuildFromProductId = null;
let currentClientId = null;
let currentExtraLines = [];
// The most recent quote, so renderExtraLines() can show what a % row actually
// adds without recomputing the base — a second computation is how a breakdown
// stops agreeing with the total above it. Set by updateGrandTotal().
let lastQuote = null;
// Extra material rows for the current part being configured
let currentExtraMaterials = [];
// BOM: non-printed components + assembly count carried from a product into the order.
let currentComponents = [];
let currentAssemblyQty = 1;

// Feature 5: Price tiers for the current part being configured
let currentPriceTiers = [];

/* ============================================================
   Electricity tariff auto-fill (Calculator → "📍 Auto")
   Approximate commercial/SME rates in LOCAL currency per kWh — starting values
   only; users adjust to their actual bill (rates vary by tier/region/season).
   There is no free global electricity-price API, so this is a maintained table.
   ============================================================ */
const ELEC_TARIFFS = {
  SA: { name: 'Saudi Arabia',         rate: 0.18,  currency: 'SAR' },
  AE: { name: 'United Arab Emirates', rate: 0.38,  currency: 'AED' },
  QA: { name: 'Qatar',                rate: 0.13,  currency: 'QAR' },
  KW: { name: 'Kuwait',               rate: 0.025, currency: 'KWD' },
  BH: { name: 'Bahrain',              rate: 0.016, currency: 'BHD' },
  OM: { name: 'Oman',                 rate: 0.024, currency: 'OMR' },
  EG: { name: 'Egypt',                rate: 1.65,  currency: 'EGP' },
  JO: { name: 'Jordan',               rate: 0.10,  currency: 'JOD' },
  IQ: { name: 'Iraq',                 rate: 72,    currency: 'IQD' },
  MA: { name: 'Morocco',              rate: 1.20,  currency: 'MAD' },
  TN: { name: 'Tunisia',              rate: 0.30,  currency: 'TND' },
  DZ: { name: 'Algeria',              rate: 4.50,  currency: 'DZD' },
  TR: { name: 'Türkiye',              rate: 2.60,  currency: 'TRY' },
  US: { name: 'United States',        rate: 0.13,  currency: 'USD' },
  CA: { name: 'Canada',               rate: 0.14,  currency: 'CAD' },
  GB: { name: 'United Kingdom',       rate: 0.25,  currency: 'GBP' },
  DE: { name: 'Germany',              rate: 0.22,  currency: 'EUR' },
  FR: { name: 'France',               rate: 0.18,  currency: 'EUR' },
  IN: { name: 'India',                rate: 8.0,   currency: 'INR' },
  CN: { name: 'China',                rate: 0.65,  currency: 'CNY' },
  JP: { name: 'Japan',                rate: 22,    currency: 'JPY' },
  AU: { name: 'Australia',            rate: 0.30,  currency: 'AUD' },
  BR: { name: 'Brazil',               rate: 0.80,  currency: 'BRL' },
  ZA: { name: 'South Africa',         rate: 2.50,  currency: 'ZAR' },
  NG: { name: 'Nigeria',              rate: 70,    currency: 'NGN' },
};

// Best-effort base-currency → default country, to preselect the picker.
const CURRENCY_DEFAULT_COUNTRY = {
  SAR: 'SA', AED: 'AE', QAR: 'QA', KWD: 'KW', BHD: 'BH', OMR: 'OM', EGP: 'EG',
  JOD: 'JO', IQD: 'IQ', MAD: 'MA', TND: 'TN', DZD: 'DZ', TRY: 'TR', USD: 'US',
  CAD: 'CA', GBP: 'GB', EUR: 'DE', INR: 'IN', CNY: 'CN', JPY: 'JP', AUD: 'AU',
  BRL: 'BR', ZAR: 'ZA', NGN: 'NG',
};

/** Resolve a country's tariff into the shop's base currency when possible. */
function electricityRateForCountry(countryCode) {
  const tar = ELEC_TARIFFS[countryCode];
  if (!tar) return null;
  const base = (typeof settings !== 'undefined' && settings.currency) || 'SAR';
  if (tar.currency === base) return { rate: tar.rate, currency: base, converted: false };
  const xr = (settings.exchangeRates || {})[tar.currency];
  if (xr && xr > 0) {
    return { rate: +(tar.rate * xr).toFixed(3), currency: base, converted: true, from: tar.currency };
  }
  // No exchange rate set — hand back the local value flagged so the UI can warn.
  return { rate: tar.rate, currency: tar.currency, converted: false, noConvert: true };
}

/** Calculator "📍 Auto": ask the user for their country, then fill #elecRate. */
function openElecRatePicker() {
  const base = (typeof settings !== 'undefined' && settings.currency) || 'SAR';
  const defCountry = CURRENCY_DEFAULT_COUNTRY[base] || 'SA';
  const opts = Object.entries(ELEC_TARIFFS)
    .sort((a, b) => a[1].name.localeCompare(b[1].name))
    .map(([code, tar]) => `<option value="${escapeHtml(code)}"${code === defCountry ? ' selected' : ''}>${escapeHtml(tar.name)}</option>`)
    .join('');
  const renderPreview = (r) => {
    if (!r) return '';
    if (r.noConvert) {
      return (t('calc.elec_preview_local') || '≈ {rate} {cur}/kWh — no {cur}→{base} rate set; value kept in {cur}. Fetch exchange rates in Settings to convert.')
        .replace(/{rate}/g, r.rate).replace(/{cur}/g, r.currency).replace(/{base}/g, base);
    }
    return (t('calc.elec_preview') || '≈ {rate} {base}/kWh').replace('{rate}', r.rate).replace('{base}', r.currency)
      + (r.converted ? ` (${(t('calc.elec_converted') || 'converted from {from}').replace('{from}', r.from)})` : '');
  };
  openFormModal({
    title: t('calc.elec_pick_title') || 'Auto-fill electricity rate',
    sizeLg: false,
    saveLabel: t('calc.elec_fill') || 'Fill rate',
    bodyHtml: `
      <p style="font-size:12.5px;color:var(--text-muted);margin:0 0 10px;">
        ${escapeHtml(t('calc.elec_pick_hint') || 'Pick your country to fill a typical commercial electricity rate. These are approximate starting values — adjust to match your actual bill.')}
      </p>
      <label style="font-size:12px;font-weight:600;">${escapeHtml(t('calc.elec_country') || 'Country / location')}</label>
      <select id="elecCountrySel" style="width:100%;margin-top:4px;">${opts}</select>
      <p id="elecPickPreview" style="font-size:12px;color:var(--text-muted);margin:10px 0 0;"></p>`,
    onMount() {
      const sel = $('#elecCountrySel');
      const prev = $('#elecPickPreview');
      if (!sel || !prev) return;
      const upd = () => { prev.textContent = renderPreview(electricityRateForCountry(sel.value)); };
      sel.addEventListener('change', upd);
      upd();
    },
    onSave() {
      const sel = $('#elecCountrySel');
      const r = sel && electricityRateForCountry(sel.value);
      if (!r) return true;
      const input = $('#elecRate');
      if (input) {
        input.value = r.rate;
        input.dispatchEvent(new Event('input', { bubbles: true }));
      }
      const cc = ELEC_TARIFFS[sel.value];
      toast((t('calc.elec_filled') || 'Electricity set to {rate} {cur}/kWh ({country})')
        .replace('{rate}', r.rate).replace('{cur}', r.currency).replace('{country}', cc ? cc.name : sel.value),
        r.noConvert ? 'warning' : 'success', 4000);
      return true;
    },
  });
}

if (typeof document !== 'undefined') {
  document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('btnElecAuto')?.addEventListener('click', openElecRatePicker);
  }, { once: true });
}

// Restore in-progress build from previous session (browser only)
(function restoreCurrentBuild() {
  if (typeof loadJSON !== 'function' || typeof document === 'undefined') return;
  const saved = loadJSON(CURRENT_BUILD_KEY, null);
  if (saved && Array.isArray(saved.parts) && saved.parts.length > 0) {
    currentBuild = saved.parts;
    currentBuildFromProductId = saved.productId || null;
    currentClientId = saved.clientId || null;
    currentExtraLines = saved.extraLines || [];
    // Show toast after DOM ready
    document.addEventListener('DOMContentLoaded', () => {
      setTimeout(() => toast(t('calc.draft_restored'), 'info', 3000), 600);
    }, { once: true });
    // Restore calculator form state after DOM is ready
    if (saved.formState) {
      document.addEventListener('DOMContentLoaded', () => {
        const fs = saved.formState;
        if ($('#margin') && fs.margin)             $('#margin').value       = fs.margin;
        if ($('#spoolCost') && fs.spoolCost)       $('#spoolCost').value    = fs.spoolCost;
        if ($('#spoolWeight') && fs.spoolWeight)   $('#spoolWeight').value  = fs.spoolWeight;
        if ($('#partQty') && fs.partQty)           $('#partQty').value      = fs.partQty;
        if ($('#partName') && fs.partName)         $('#partName').value     = fs.partName;
        if ($('#printWeight') && fs.printWeight)   $('#printWeight').value  = fs.printWeight;
        if ($('#printTime') && fs.printTime)       $('#printTime').value    = fs.printTime;
        if ($('#resinLayers') && fs.resinLayers)           $('#resinLayers').value           = fs.resinLayers;
        if ($('#resinLayerHeight') && fs.resinLayerHeight) $('#resinLayerHeight').value       = fs.resinLayerHeight;
        if ($('#resinExposure') && fs.resinExposure)       $('#resinExposure').value          = fs.resinExposure;
        if ($('#resinBaseLayers') && fs.resinBaseLayers)   $('#resinBaseLayers').value        = fs.resinBaseLayers;
        if ($('#resinBaseExposure') && fs.resinBaseExposure) $('#resinBaseExposure').value    = fs.resinBaseExposure;
        updateResinFieldsVisibility();
        // filamentSelect needs to be restored after the select is populated
        if (fs.filamentId) {
          setTimeout(() => {
            if ($('#filamentSelect')) $('#filamentSelect').value = fs.filamentId;
            updateResinFieldsVisibility();
          }, 100);
        }
      }, { once: true });
    }
  }
})();

function saveBuildDraft() {
  if (currentBuild.length === 0) {
    localStorage.removeItem(CURRENT_BUILD_KEY);
    return;
  }
  saveJSON(CURRENT_BUILD_KEY, {
    parts:      currentBuild,
    productId:  currentBuildFromProductId,
    clientId:   currentClientId,
    extraLines: currentExtraLines,
    savedAt:    new Date().toISOString(),
    // Persist calculator form state
    formState: {
      margin:      $('#margin')?.value || '',
      filamentId:  $('#filamentSelect')?.value || '',
      spoolCost:   $('#spoolCost')?.value || '',
      spoolWeight: $('#spoolWeight')?.value || '',
      partQty:     $('#partQty')?.value || '1',
      partName:    $('#partName')?.value || '',
      printWeight: $('#printWeight')?.value || '',
      printTime:   $('#printTime')?.value || '',
      resinLayers:       $('#resinLayers')?.value || '',
      resinLayerHeight:  $('#resinLayerHeight')?.value || '0.05',
      resinExposure:     $('#resinExposure')?.value || '',
      resinBaseLayers:   $('#resinBaseLayers')?.value || '',
      resinBaseExposure: $('#resinBaseExposure')?.value || '',
    },
  });
}
(function (global) {
/* ============================================================
   Calculator
   ============================================================ */
// Returns { rate, n } suggestion from waste history for a machine+material pair,
// or null if there is insufficient data (< 5 completed jobs).
function suggestedFailureRate(machineId, material) {
  if (!machineId || !material) return null;
  const mat = material.toLowerCase();
  const completed = printLog.filter(o =>
    o.machineId === machineId &&
    o.status === 'completed' &&
    ((o.material || '').toLowerCase() === mat ||
     (o.parts || []).some(p => (p.material || '').toLowerCase() === mat))
  );
  if (completed.length < 5) return null;
  const wastes = wasteLog.filter(w =>
    w.machineId === machineId &&
    (w.material || '').toLowerCase() === mat
  );
  const rate = Math.round((wastes.length / completed.length) * 1000) / 10;
  return { rate, n: completed.length };
}

function updateFailureRateHint() {
  const hint = $('#failureRateHint');
  if (!hint) return;
  const machineId = $('#partMachineId')?.value || '';
  const filamentSel = $('#filamentSelect');
  const material = filamentSel?.options[filamentSel.selectedIndex]?.dataset?.material ||
    (filamentSel?.value ? (inventory.find(i => i.id === filamentSel.value)?.material || '') : '');
  const sugg = suggestedFailureRate(machineId, material);
  if (sugg) {
    hint.textContent = `↗ ${t('calc.fail_suggested') || 'suggested'}: ${sugg.rate}% (${sugg.n} ${t('an.jobs') || 'jobs'})`;
  } else {
    hint.textContent = '';
  }
}

/* computePartBaseCost, getActivePriceTier, computePartBreakdown — lib/calculator-cost.js */

function calculateLivePartCost() {
  // Snapshot the DOM into a part-shaped object and reuse the pure helper.
  // qty and filamentId MUST be included or the live preview disagrees with the cart:
  // packaging is divided by qty (so a 20-unit part previewed at 17.00 and landed in the
  // cart at 7.50), and filamentId selects the resin per-kg cost branch, so a resin part
  // silently changed price on being added.
  return computePartBaseCost({
    qty:           $('#partQty')?.value || 1,
    filamentId:    $('#filamentSelect')?.value || '',
    spoolCost:     $('#spoolCost').value,
    spoolWeight:   $('#spoolWeight').value,
    printWeight:   $('#printWeight').value,
    supportWeight: $('#supportWeight')?.value || 0,
    printTime:     $('#printTime').value,
    wearRate:      $('#wearRate').value,
    powerDraw:     $('#powerDraw').value,
    elecRate:      $('#elecRate').value,
    prepTime:      $('#prepTime').value,
    postTime:      $('#postTime').value,
    laborRate:     $('#laborRate').value,
    failureRate:   $('#failureRate').value,
    extraMaterials: currentExtraMaterials.filter(m => m.material && m.weight > 0),
  });
}

/** AI price assist: recommend a margin from the shop's realized history for the
 *  selected material, grounded in comparable completed jobs. Deterministic
 *  baseline; an AI rationale is layered on when AI assist is enabled. */
async function aiSuggestPrice() {
  if (typeof KhaytAiPrice === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
  const fsel = $('#filamentSelect');
  const material = fsel?.options?.[fsel.selectedIndex]?.text || '';
  const comps = KhaytAiPrice.buildComparables(printLog, { material, now: Date.now() });
  if (!comps.count) { toast(t('ai.price_no_history') || 'Not enough priced history yet', 'error'); return; }

  // Current job cost + specs (mirrors updateGrandTotal).
  const qty = Math.max(1, Math.round(num($('#partQty').value, 1)));
  const cost = currentBuild.length
    ? currentBuild.reduce((s, p) => s + (+p.baseCost || 0), 0)
    : calculateLivePartCost() * qty;
  const grams = currentBuild.length
    ? currentBuild.reduce((s, p) => s + ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1), 0)
    : ((clampPositive($('#printWeight').value) + num($('#supportWeight')?.value, 0)) * qty);
  const hours = currentBuild.length
    ? currentBuild.reduce((s, p) => s + (+p.printTime || 0) * (+p.qty || 1), 0)
    : clampPositive($('#printTime').value) * qty;
  const cur = (typeof currencySymbol === 'function') ? currencySymbol() : '';

  // Default to the deterministic suggestion (median realized margin).
  let reco = { suggestedMargin: comps.suggestedMargin, suggestedPrice: cost > 0 ? Math.round((cost / (1 - comps.suggestedMargin / 100)) * 100) / 100 : null, rationale: '' };

  const ai = settings.ai || {};
  // Per-feature consent, not just the master switch — see lib/ai-privacy.js.
  const useAi = !!(ai.apiKey && window.KhaytAiPrivacy.isFeatureEnabled(ai, 'price'));
  if (useAi) {
    const status = toast(t('ai.price_thinking') || 'Analyzing your pricing history…', 'info', 8000);
    try {
      const system = KhaytAiPrice.buildPriceSystem({ shopName: shopField('biz') || 'Khayt', lang: settings.lang });
      const request = KhaytAiPrice.buildPriceRequest(comps, { material, grams, hours, cost, currency: cur });
      const r = await khaytAiExtract({ apiKey: ai.apiKey, model: ai.model || 'claude-opus-5', task: 'price', system, request, schema: KhaytAiPrice.PRICE_SCHEMA });
      if (r && r.ok) reco = KhaytAiPrice.pickPrice(r, reco) || reco;
    } catch (_) { /* fall back to deterministic */ }
  }

  const basisLabel = comps.basis === 'material'
    ? (t('ai.price_basis_material') || 'similar {material} jobs').replace('{material}', comps.material || material)
    : (t('ai.price_basis_all') || 'your priced jobs');
  const line = (t('ai.price_summary') || '{count} {basis}: median margin {med}% (range {min}–{max}%)')
    .replace('{count}', comps.count).replace('{basis}', basisLabel)
    .replace('{med}', comps.medianMarginPct).replace('{min}', comps.minMarginPct).replace('{max}', comps.maxMarginPct);

  openFormModal({
    title: t('ai.price_title') || 'AI price suggestion',
    saveLabel: t('ai.price_apply') || 'Apply margin',
    bodyHtml: `
      <p style="font-size:13px;margin:0 0 8px;">${escapeHtml(line)}</p>
      ${reco.rationale ? `<p style="font-size:13px;color:var(--text-muted);margin:0 0 10px;">${escapeHtml(reco.rationale)}</p>` : ''}
      <div style="display:flex;gap:16px;align-items:baseline;">
        <div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('calc.quote.margin') || 'Target margin')}</div><div style="font-size:22px;font-weight:700;">${escapeHtml(String(reco.suggestedMargin))}%</div></div>
        ${reco.suggestedPrice != null ? `<div><div style="font-size:11px;color:var(--text-muted);">${escapeHtml(t('ai.price_suggested') || 'Suggested price')}</div><div style="font-size:22px;font-weight:700;">${escapeHtml(fmtMoney(reco.suggestedPrice))}</div></div>` : ''}
      </div>`,
    onSave() {
      const m = $('#margin');
      if (m) { m.value = String(reco.suggestedMargin); updateGrandTotal(); }
      toast(t('ai.price_applied') || 'Margin applied', 'success');
      return true;
    },
  });
}

/** Populate the quote currency selector (once): "Auto" + every known currency. */
function populateCalcCurrency() {
  const sel = $('#calcCurrency');
  if (!sel || sel.options.length) return;
  const base = settings.currency || 'SAR';
  const auto = (t('calc.currency_auto') || 'Auto') + (base ? ` (${base})` : '');
  const opts = [`<option value="">${escapeHtml(auto)}</option>`];
  for (const [code, cur] of Object.entries(CURRENCIES || {})) {
    opts.push(`<option value="${escapeHtml(code)}">${escapeHtml(cur.label || code)}</option>`);
  }
  sel.innerHTML = opts.join('');
}

function updateGrandTotal() {
  populateCalcCurrency();
  const snap = {
    spoolCost: $('#spoolCost').value, spoolWeight: $('#spoolWeight').value,
    printWeight: $('#printWeight').value, supportWeight: $('#supportWeight')?.value || 0,
    printTime: $('#printTime').value,
    wearRate: $('#wearRate').value, powerDraw: $('#powerDraw').value,
    elecRate: $('#elecRate').value, prepTime: $('#prepTime').value,
    postTime: $('#postTime').value, laborRate: $('#laborRate').value,
    failureRate: $('#failureRate').value,
    filamentId: $('#filamentSelect')?.value || '',
    extraMaterials: currentExtraMaterials.filter(m => m.material && m.weight > 0),
  };
  const bd = computePartBreakdown(snap);
  const liveBase = bd.material + bd.machine + bd.labor + bd.buffer;
  const qty = Math.max(1, Math.round(num($('#partQty').value, 1)));
  // Enthusiast (hobbyist) mode prices nothing: no margin, discount, fees or
  // selling price — the "total" is pure cost. Business modes are unchanged.
  const biz = (typeof KhaytTiers !== 'undefined')
    ? KhaytTiers.showsBusiness(settings.mode)
    : (settings.mode !== 'enthusiast');
  const margin = biz ? clampPositive($('#margin').value) : 0;
  // Apply price tier if one matches current qty. Selection lives in lib/pricing.js
  // so the LAN quote endpoint resolves tiers the same way this screen does.
  const activeTier = KhaytPricing.activePriceTier(currentPriceTiers, qty);
  const liveUnitPrice = activeTier
    ? activeTier.pricePerUnit
    : liveBase * (1 + margin / 100);
  $('#partLivePrice').textContent = fmtMoney(liveUnitPrice * qty);

  // Cost breakdown chips
  const bdEl = $('#costBreakdown');
  if (bdEl) {
    const items = [
      { key: 'calc.bd.material', val: bd.material },
      { key: 'calc.bd.machine',  val: bd.machine  },
      { key: 'calc.bd.labor',    val: bd.labor    },
      { key: 'calc.bd.buffer',   val: bd.buffer   },
    ].filter(x => x.val >= 0.01);
    if (items.length > 0) {
      bdEl.innerHTML = items.map(x =>
        `<span class="bd-item"><span class="bd-label">${escapeHtml(t(x.key))}</span> <b>${fmtMoney(x.val)}</b></span>`
      ).join('');
      bdEl.style.display = 'flex';
    } else {
      bdEl.style.display = 'none';
    }
  }

  let totalBase = 0;
  if (currentBuild.length > 0) {
    totalBase = currentBuild.reduce((s, p) => s + (+p.baseCost || 0), 0);
  } else {
    totalBase = liveBase * qty;
  }
  const discountPct = biz ? Math.min(100, Math.max(0, num($('#discountPct').value, 0))) : 0;
  const shippingCost = biz ? Math.max(0, num($('#shippingCost')?.value, 0)) : 0;
  const rushEnabled = biz && !!$('#calcRushFee')?.checked;
  const rushPct = rushEnabled ? num(settings.rushFeePct, 25) : 0;
  // The maths now lives in lib/pricing.js, so a quote from the phone can reach
  // the same number this screen shows. Extracted verbatim — the order of
  // operations (rush AFTER the discount; shipping and extras after both) is
  // baked into quotes already sent, and test/pricing.test.js pins the extracted
  // form against the original expressions over 4,000 randomised cases.
  //
  // A price tier applies only to a single live part, never to a multi-line cart:
  // that rule stays here, with the code that knows what a cart is.
  const _q = KhaytPricing.quoteTotal({
    baseCost: totalBase,
    qty,
    margin,
    priceTier: currentBuild.length === 0 ? activeTier : null,
    discountPct,
    rushEnabled,
    rushPct,
    shippingCost,
    extraLines: biz ? currentExtraLines : [],
    business: biz,
  });
  const priceBeforeDiscount = _q.priceBeforeDiscount;
  const discountAmt = _q.discountAmount;
  const subAfterDiscount = _q.subtotal;
  const rushFeeAmt = _q.rushFee;
  const finalPrice = _q.total;
  lastQuote = _q;
  // Update the resolved money on percentage rows without touching the inputs:
  // renderExtraLines() rebuilds them, which would steal focus mid-keystroke.
  if (typeof KhaytPricing !== 'undefined' && KhaytPricing.resolveExtraLines) {
    const resolved = KhaytPricing.resolveExtraLines(currentExtraLines, _q.extrasBase || 0);
    document.querySelectorAll('#extraLinesList .extra-line-row').forEach((row, i) => {
      const span = row.querySelector('.el-resolved');
      if (span && resolved[i]) span.textContent = fmtMoney(resolved[i].amount);
    });
  }
  const finalEl = $('#finalPrice');
  if (finalEl) {
    if (!finalEl.getAttribute('aria-live')) finalEl.setAttribute('aria-live', 'polite');
    finalEl.textContent = fmtMoney(finalPrice);
  }
  // In enthusiast mode the "Project total" is really the cost — relabel it.
  const totalLabel = document.querySelector('.total-display .label');
  if (totalLabel) totalLabel.textContent = biz
    ? (t('calc.quote.total') || 'Project total')
    : (t('calc.total_cost') || 'Total cost');

  let bdForChart = bd;
  let breakdownScope = 'live';
  if (currentBuild.length > 0) {
    bdForChart = currentBuild.reduce((acc, part) => {
      const partBd = computePartBreakdown(part);
      const q = Math.max(1, +part.qty || 1);
      acc.material += partBd.material * q;
      acc.machine += partBd.machine * q;
      acc.labor += partBd.labor * q;
      acc.buffer += partBd.buffer * q;
      return acc;
    }, { material: 0, machine: 0, labor: 0, buffer: 0 });
    breakdownScope = 'cart';
  }
  window.KhaytBedReadyUI?.updateCalcBreakdown?.(bdForChart, {
    currency: settings.currency,
    margin,
    finalPrice,
    breakdownScope,
  });

  const discountLine = $('#discountLine');
  if (discountLine) {
    if (discountPct > 0) {
      discountLine.textContent = `−${fmtMoney(discountAmt)} (${discountPct}%)`;
      discountLine.style.display = 'inline';
    } else {
      discountLine.style.display = 'none';
    }
  }

  // Rush fee chip
  const rushChip = $('#rushFeeChip');
  if (rushChip) {
    if (rushEnabled && rushFeeAmt > 0) {
      rushChip.textContent = `⚡ ${t('calc.rush_fee')}: +${rushPct}% (${fmtMoney(rushFeeAmt)})`;
      rushChip.style.display = 'inline-block';
    } else {
      rushChip.style.display = 'none';
    }
  }

  // Min-margin warning + live margin display
  const marginWarn = $('#marginWarning');
  // Extra charges are FEES billed to the customer ("Extra charges" / "+ Add fee") — pure
  // revenue with no matching cost. They were added to finalPrice AND subtracted here as
  // cost, so adding a 100 fee to a 30%-margin job dropped the displayed margin to 17.6%
  // when it should rise to 58.8%. Shipping is deliberately still counted on both sides:
  // the shop bills it and pays the carrier, so it should not inflate margin.
  const actualMarginPct = finalPrice > 0 ? ((finalPrice - (totalBase + shippingCost)) / finalPrice) * 100 : margin;
  if (marginWarn) {
    const minPct = num(settings.minMarginPct, 0);
    const marginColor = actualMarginPct >= 40 ? 'var(--success)' : actualMarginPct >= 20 ? 'var(--warning)' : 'var(--danger)';
    const marginDisplay = `<span style="color:${marginColor}; font-weight:600;">${actualMarginPct.toFixed(0)}% margin</span>`;
    if (minPct > 0 && actualMarginPct < minPct) {
      marginWarn.innerHTML = `${marginDisplay} — ${escapeHtml(t('calc.margin_warn', { min: minPct.toFixed(0), actual: actualMarginPct.toFixed(0) }))}`;
      marginWarn.style.display = 'block';
    } else if (totalBase > 0) {
      marginWarn.innerHTML = marginDisplay;
      marginWarn.style.display = 'block';
    } else {
      marginWarn.style.display = 'none';
    }
  }

  // Min order amount warning
  const minOrderWarn = $('#minOrderWarning');
  if (minOrderWarn) {
    const minAmt = num(settings.minOrderAmount, 0);
    if (minAmt > 0 && finalPrice < minAmt) {
      minOrderWarn.textContent = t('calc.min_order_warn', { min: fmtMoney(minAmt) });
      minOrderWarn.style.display = 'block';
    } else {
      minOrderWarn.style.display = 'none';
    }
  }
}

function snapshotPartFromForm() {
  const filamentSelect = $('#filamentSelect');
  const opt = filamentSelect.options[filamentSelect.selectedIndex];
  const qty = Math.max(1, Math.round(num($('#partQty').value, 1)));
  const unitCost = calculateLivePartCost();
  return {
    name:          $('#partName').value.trim() || t('calc.part.name_ph'),
    colour:        ($('#partColour')?.value || '').trim(),
    partNote:      ($('#partNote')?.value || '').trim(),
    material:      opt?.text || '',
    filamentId:    filamentSelect.value,
    spoolCost:     clampPositive($('#spoolCost').value),
    spoolWeight:   Math.max(1, num($('#spoolWeight').value, 1)),
    printWeight:   clampPositive($('#printWeight').value),
    supportWeight: Math.max(0, num($('#supportWeight')?.value, 0)),
    printTime:     clampPositive($('#printTime').value),
    wearRate:    clampPositive($('#wearRate').value),
    powerDraw:   clampPositive($('#powerDraw').value),
    elecRate:    clampPositive($('#elecRate').value),
    prepTime:    clampPositive($('#prepTime').value),
    postTime:    clampPositive($('#postTime').value),
    laborRate:   clampPositive($('#laborRate').value),
    failureRate: clampPositive($('#failureRate').value),
    qty,
    unitCost,
    baseCost:    (() => {
      // Feature 5: If a price tier applies, baseCost is the tier total (already includes margin)
      // divided by margin factor so the quote flow doesn't double-apply margin
      const tiers = currentPriceTiers.filter(ti => ti.minQty > 0 && ti.pricePerUnit > 0);
      if (tiers.length > 0) {
        const sorted = [...tiers].sort((a, b) => a.minQty - b.minQty);
        const tier = [...sorted].reverse().find(ti => qty >= ti.minQty);
        if (tier) {
          const marginPct = Math.max(0, num($('#margin').value, 0));
          const tierTotal = +tier.pricePerUnit * qty;
          // Store as baseCost such that baseCost * (1 + margin/100) ≈ tierTotal
          return marginPct > 0 ? tierTotal / (1 + marginPct / 100) : tierTotal;
        }
      }
      return unitCost * qty;
    })(),
    layerHeight: num($('#layerHeight')?.value, 0) || null,
    infill:      num($('#infill')?.value, 0) || null,
    profile:     ($('#printProfile')?.value || '').trim() || null,
    machineId:   $('#partMachineId')?.value || null,
    fileRef:     ($('#partFileRef')?.value || '').trim() || '',
    // The link that lets a finished job teach the file it printed: which model,
    // and which of its setups. See lib/order-file-link.js.
    printFileId: $('#partPrintFile')?.value || null,
    setupId:     $('#partSetup')?.value || null,
    extraMaterials: currentExtraMaterials.filter(m => m.material && m.weight > 0).map(m => ({ ...m })),
    priceTiers:  currentPriceTiers.filter(ti => ti.minQty > 0 && ti.pricePerUnit > 0).map(ti => ({ ...ti })),
    spoolId:     $('#spoolIdPicker')?.value || null,
  };
}

function addPart() {
  const printWeight = clampPositive($('#printWeight').value);
  const printTime = clampPositive($('#printTime').value);
  if (printWeight <= 0 && printTime <= 0) {
    toast(t('calc.quote.empty'), 'error');
    return;
  }
  const part = snapshotPartFromForm();
  part.id = uid('PRT');
  currentBuild.push(part);

  $('#partName').value = '';
  if ($('#partColour')) $('#partColour').value = '';
  if ($('#partNote'))   $('#partNote').value   = '';
  if ($('#supportWeight')) $('#supportWeight').value = '';
  $('#printWeight').value = '';
  $('#printTime').value = '';
  $('#partQty').value = '1';
  if ($('#layerHeight'))  $('#layerHeight').value  = '';
  if ($('#infill'))       $('#infill').value        = '';
  if ($('#printProfile')) $('#printProfile').value  = '';
  // The attached file was NOT cleared, so it silently carried over onto the next part —
  // the second item in a multi-part order ended up referencing the first item's model.
  if ($('#partFileRef')) $('#partFileRef').value = '';
  // Same reason the file reference is cleared: a second part in one order must
  // not silently inherit the first part's model and settings.
  // The estimate note belongs to the part that just left the form. wireEvents()
  // owns it, and forgets the model it was derived from when it hears this.
  //
  // Announced BEFORE the pickers are cleared, not after. Clearing #partPrintFile
  // fires a `change`, and wireEvents recomputes the estimate on that — so with
  // the order reversed the estimate was recomputed into a form that was in the
  // middle of being emptied, refilling the weight of the part that had just
  // left. Forget the model first, and the change that follows finds nothing.
  try { document.dispatchEvent(new CustomEvent('khayt:calc-part-added')); } catch (e) { /* non-fatal */ }
  if ($('#partPrintFile')) { $('#partPrintFile').value = ''; $('#partPrintFile').dispatchEvent(new Event('change', { bubbles: true })); }
  currentExtraMaterials = [];
  currentPriceTiers = [];
  renderExtraMaterials();
  renderPriceTiers();
  const addBtn = $('#btnAddPart');
  if (addBtn && addBtn.dataset.editing) {
    addBtn.textContent = t('calc.quote.add_part');
    delete addBtn.dataset.editing;
  }
  renderBuild();
  saveBuildDraft();
}

function removePart(index) {
  currentBuild.splice(index, 1);
  renderBuild();
  saveBuildDraft();
}

function editPart(index) {
  const part = currentBuild[index];
  if (!part) return;

  // Restore form fields from the saved part snapshot
  $('#partName').value      = part.name;
  $('#partQty').value       = part.qty || 1;
  $('#printWeight').value   = part.printWeight || '';
  $('#printTime').value     = part.printTime || '';
  $('#spoolCost').value     = part.spoolCost || '';
  $('#spoolWeight').value   = part.spoolWeight || '';
  $('#wearRate').value      = part.wearRate || '';
  $('#powerDraw').value     = part.powerDraw || '';
  $('#elecRate').value      = part.elecRate || '';
  $('#prepTime').value      = part.prepTime || '';
  $('#postTime').value      = part.postTime || '';
  $('#laborRate').value     = part.laborRate || '';
  $('#failureRate').value   = part.failureRate || '';

  if (part.filamentId) {
    const sel = $('#filamentSelect');
    const opt = Array.from(sel.options).find(o => o.value === part.filamentId);
    if (opt) sel.value = part.filamentId;
  }
  const partMachSel = $('#partMachineId');
  if (partMachSel) partMachSel.value = part.machineId || '';

  // These were stored by the cart but never restored, so editing a line silently
  // discarded them. supportWeight is a COST DRIVER — re-adding the part re-priced it
  // lower — and the rest (colour, note, layer height, infill, profile, file, spool) were
  // simply lost. `material` and `baseCost` are deliberately absent: both are derived on
  // save from the filament selection.
  const setVal = (sel, v) => { const el = $(sel); if (el) el.value = (v ?? ''); };
  setVal('#supportWeight', part.supportWeight || '');
  setVal('#partColour',    part.colour || '');
  setVal('#partNote',      part.partNote || '');
  setVal('#layerHeight',   part.layerHeight || '');
  setVal('#infill',        part.infill || '');
  setVal('#printProfile',  part.profile || '');
  setVal('#partFileRef',   part.fileRef || '');
  if ($('#partPrintFile')) {
    $('#partPrintFile').value = part.printFileId || '';
    $('#partPrintFile').dispatchEvent(new Event('change', { bubbles: true }));
    if ($('#partSetup')) $('#partSetup').value = part.setupId || '';
  }
  setVal('#spoolIdPicker', part.spoolId || '');

  // Restore extra materials
  currentExtraMaterials = (part.extraMaterials || []).map(m => ({ ...m }));
  renderExtraMaterials();

  // Feature 5: Restore price tiers
  currentPriceTiers = (part.priceTiers || []).map(ti => ({ ...ti }));
  renderPriceTiers();

  currentBuild.splice(index, 1);
  renderBuild();
  calculateLivePartCost();
  updateFailureRateHint();

  // Scroll form into view and highlight the add button
  const addBtn = $('#btnAddPart');
  if (addBtn) {
    addBtn.textContent = t('calc.cart.update');
    addBtn.dataset.editing = '1';
    addBtn.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }
}

function renderBuild() {
  const tbody = $('#buildTableBody');
  if (currentBuild.length === 0) {
    tbody.innerHTML = `<tr><td colspan="3" class="empty" style="text-align:center;padding:14px;color:var(--text-muted);font-size:12.5px;">${escapeHtml(t('calc.quote.empty'))}</td></tr>`;
  } else {
    tbody.innerHTML = currentBuild.map((part, i) => {
      const psHint = [
        part.layerHeight ? `${part.layerHeight}mm` : '',
        part.infill      ? `${part.infill}%`        : '',
        part.profile     || ''
      ].filter(Boolean).join(' · ');
      const partMachine = part.machineId ? machines.find(m => m.id === part.machineId) : null;
      // Feature 5: Check if a price tier is applied
      let tierBadge = '';
      if (part.priceTiers && part.priceTiers.length > 0 && part.qty > 0) {
        const sorted = [...part.priceTiers].sort((a, b) => a.minQty - b.minQty);
        const tier = [...sorted].reverse().find(ti => +part.qty >= +ti.minQty);
        if (tier) {
          tierBadge = `<span class="tier-applied-badge">${escapeHtml(t('calc.tier_applied', { n: tier.minQty }))}</span>`;
        }
      }
      return `
      <tr>
        <td>
          <strong>${escapeHtml(part.name)}</strong>
          ${partMachine ? `<span class="machine-badge" style="background:${safeCssColor(partMachine.color)}; font-size:10px; padding:1px 6px; vertical-align:middle; margin-inline-start:4px;">${escapeHtml(partMachine.name)}</span>` : ''}
          ${tierBadge}
          <div style="font-size: 11.5px; color: var(--text-muted); margin-top: 2px;">${escapeHtml(part.material)}</div>
          ${(part.extraMaterials || []).filter(m => m.material).map(m =>
            `<div style="font-size:11px; color:var(--text-muted); margin-inline-start:8px;">+ ${escapeHtml(m.material)} ${m.weight ? m.weight + 'g' : ''}</div>`
          ).join('')}
          ${psHint ? `<div style="font-size:10.5px; color:var(--text-muted); margin-top:1px; font-style:italic;">${escapeHtml(psHint)}</div>` : ''}
          ${part.fileRef ? `<div class="part-file-ref">📎 ${escapeHtml(part.fileRef)}</div>` : ''}
          ${part.colour ? `<div style="font-size:11px;color:var(--text-muted);margin-top:1px;">🎨 ${escapeHtml(part.colour)}</div>` : ''}
          ${part.partNote ? `<div style="font-size:11px;color:var(--text-dim);margin-top:1px;font-style:italic;">📝 ${escapeHtml(part.partNote)}</div>` : ''}
        </td>
        <td style="text-align: end; font-variant-numeric: tabular-nums; white-space:nowrap;">
          ${part.printTime} ${escapeHtml(t('common.hours'))}
          ${(part.qty && part.qty > 1) ? `<span style="color:var(--primary); margin-inline-start:4px;">×${part.qty}</span>` : ''}
        </td>
        <td style="text-align: end; white-space: nowrap;">
          <button class="btn small" data-act="edit-part" data-idx="${i}" title="${escapeHtml(t('calc.cart.edit'))}" style="margin-inline-end:4px;" aria-label="${escapeHtml(t('calc.cart.edit'))}"><span aria-hidden="true">✎</span></button>
          <button class="btn danger small" data-act="remove-part" data-idx="${i}" title="${escapeHtml(t('common.delete'))}" aria-label="${escapeHtml(t('common.delete'))}"><span aria-hidden="true">×</span></button>
        </td>
      </tr>`;
    }).join('');
  }
  renderCartBanner();
  updateGrandTotal();
  updateResinFieldsVisibility();
}

/* ── Extra charges (custom invoice line items) ─────────────── */
function renderExtraLines() {
  const el = $('#extraLinesList');
  if (!el) return;
  if (currentExtraLines.length === 0) { el.innerHTML = ''; updateGrandTotal(); return; }
  // A marketplace fee is a percentage; a packaging charge is a number. The unit
  // picker is per row because a quote routinely needs both at once.
  //
  // The resolved money for a % row is read from lib/pricing.js rather than
  // worked out here — a second computation in the view is how a breakdown ends
  // up disagreeing with the total printed above it.
  const q = lastQuote || {};
  const rows = (typeof KhaytPricing !== 'undefined' && KhaytPricing.resolveExtraLines)
    ? KhaytPricing.resolveExtraLines(currentExtraLines, q.extrasBase || 0)
    : currentExtraLines.map((l) => ({ pct: null, amount: +l.amount || 0 }));
  el.innerHTML = currentExtraLines.map((line, i) => {
    const isPct = (typeof KhaytPricing !== 'undefined' && KhaytPricing.isPercentLine)
      ? KhaytPricing.isPercentLine(line) : false;
    const shown = isPct ? (line.pct || '') : (line.amount || '');
    // The money a % row actually adds, beside the percentage — the same shape
    // the rush chip already uses ("+25% (SAR 12.50)").
    const resolved = isPct && rows[i] && rows[i].amount > 0
      ? `<span class="el-resolved" style="font-size:11.5px;color:var(--text-muted);white-space:nowrap;">${escapeHtml(fmtMoney(rows[i].amount))}</span>` : '';
    return `
    <div class="extra-line-row">
      <input type="text" class="el-label" value="${escapeHtml(line.label)}" placeholder="${escapeHtml(t('calc.extra_label_ph'))}" style="flex:1; min-width:0;">
      <input type="number" class="el-amount" value="${shown}" min="0" step="0.01" placeholder="${isPct ? '0.0' : '0.00'}" style="width:80px;">
      <select class="el-unit" style="width:62px; font-size:12.5px;" aria-label="${escapeHtml(t('calc.extra_unit') || 'Fee type')}">
        <option value="amt" ${isPct ? '' : 'selected'}>${escapeHtml(currencySymbol())}</option>
        <option value="pct" ${isPct ? 'selected' : ''}>%</option>
      </select>
      ${resolved}
      <button class="btn danger small el-rm" data-eli="${i}" aria-label="Remove" title="Remove">×</button>
    </div>`; }).join('');
  el.querySelectorAll('.el-label').forEach((inp, i) => {
    inp.addEventListener('input', () => { currentExtraLines[i].label = inp.value; updateGrandTotal(); });
  });
  el.querySelectorAll('.el-amount').forEach((inp, i) => {
    inp.addEventListener('input', () => {
      const v = Math.max(0, +inp.value || 0);
      const line = currentExtraLines[i];
      // Write to whichever field this row IS. Writing both would double-charge:
      // pricing ignores a percentage row's amount, but a later edit could flip
      // the row back to fixed and resurrect a number nobody typed.
      if (KhaytPricing.isPercentLine(line)) { line.pct = v; delete line.amount; }
      else { line.amount = v; delete line.pct; }
      updateGrandTotal();
    });
  });
  el.querySelectorAll('.el-unit').forEach((sel, i) => {
    sel.addEventListener('change', () => {
      const line = currentExtraLines[i];
      // Carry the typed number across, and clear the other field so the row can
      // never hold both.
      const v = Math.max(0, +(KhaytPricing.isPercentLine(line) ? line.pct : line.amount) || 0);
      if (sel.value === 'pct') { line.pct = v; delete line.amount; }
      else { line.amount = v; delete line.pct; }
      renderExtraLines();
    });
  });
  el.querySelectorAll('.el-rm').forEach(btn => {
    btn.addEventListener('click', () => { currentExtraLines.splice(+btn.dataset.eli, 1); renderExtraLines(); });
  });
  updateGrandTotal();
}

/* ── Extra materials for current part (Feature 8) ─────────────── */
function renderExtraMaterials() {
  const el = $('#extraMaterialsList');
  if (!el) return;
  if (currentExtraMaterials.length === 0) { el.innerHTML = ''; return; }
  el.innerHTML = currentExtraMaterials.map((m, i) => {
    const matOptions = inventory.map(item =>
      `<option value="${escapeHtml(item.material)}" ${m.material === item.material ? 'selected' : ''}>${escapeHtml(item.material)}</option>`
    ).join('');
    return `<div class="extra-mat-row" data-emi="${i}" style="display:flex; gap:6px; align-items:center; margin-bottom:4px;">
      <select class="em-material" style="flex:2; font-size:12.5px;">
        <option value="">${escapeHtml(t('calc.extra_mat_name'))}</option>
        ${matOptions}
      </select>
      <input type="number" class="em-weight" value="${m.weight || ''}" min="0" step="1" placeholder="${escapeHtml(t('calc.extra_mat_weight'))}" style="width:80px; font-size:12.5px;">
      <button class="btn danger small em-rm" data-emi="${i}" aria-label="Remove" title="Remove">×</button>
    </div>`;
  }).join('');
  el.querySelectorAll('.em-material').forEach((sel, i) => {
    sel.value = currentExtraMaterials[i].material || '';
    sel.addEventListener('change', () => {
      currentExtraMaterials[i].material = sel.value;
      updateGrandTotal();
    });
  });
  el.querySelectorAll('.em-weight').forEach((inp, i) => {
    inp.addEventListener('input', () => {
      currentExtraMaterials[i].weight = Math.max(0, +inp.value || 0);
      updateGrandTotal();
    });
  });
  el.querySelectorAll('.em-rm').forEach(btn => {
    btn.addEventListener('click', () => {
      currentExtraMaterials.splice(+btn.dataset.emi, 1);
      renderExtraMaterials();
      updateGrandTotal();
    });
  });
}

/* Feature 5: Price tiers renderer */
function renderPriceTiers() {
  const el = $('#priceTiersList');
  if (!el) return;
  if (currentPriceTiers.length === 0) {
    el.innerHTML = `<p style="font-size:12px; color:var(--text-muted); margin:4px 0;">${escapeHtml(t('calc.no_price_tiers') || 'No volume tiers — click + Add tier for quantity pricing')}</p>`;
    return;
  }
  el.innerHTML = `<div style="display:grid; grid-template-columns:1fr 1fr auto; gap:4px; align-items:center; font-size:12px; color:var(--text-muted); margin-bottom:2px;">
    <span>${escapeHtml(t('calc.tier_min_qty'))}</span>
    <span>${escapeHtml(t('calc.tier_price'))} (${currencySymbol()})</span>
    <span></span>
  </div>` +
  currentPriceTiers.map((tier, i) => `
    <div class="price-tier-row" data-ti="${i}" style="display:grid; grid-template-columns:1fr 1fr auto; gap:4px; margin-bottom:4px; align-items:center;">
      <input type="number" class="pt-minqty" value="${tier.minQty || 1}" min="1" step="1" style="font-size:12.5px;">
      <input type="number" class="pt-price" value="${tier.pricePerUnit || ''}" min="0" step="0.01" style="font-size:12.5px;" placeholder="0.00">
      <button class="btn danger small pt-rm" data-ti="${i}" aria-label="Remove" title="Remove">×</button>
    </div>`).join('');
  el.querySelectorAll('.pt-minqty').forEach((inp, i) => {
    inp.addEventListener('input', () => { currentPriceTiers[i].minQty = Math.max(1, +inp.value || 1); updateGrandTotal(); });
  });
  el.querySelectorAll('.pt-price').forEach((inp, i) => {
    inp.addEventListener('input', () => { currentPriceTiers[i].pricePerUnit = Math.max(0, +inp.value || 0); updateGrandTotal(); });
  });
  el.querySelectorAll('.pt-rm').forEach(btn => {
    btn.addEventListener('click', () => { currentPriceTiers.splice(+btn.dataset.ti, 1); renderPriceTiers(); updateGrandTotal(); });
  });
}

function renderCartBanner() {
  const banner = $('#cartFromCatalogBanner');
  if (currentBuildFromProductId) {
    const p = products.find(x => x.id === currentBuildFromProductId);
    if (p) {
      banner.style.display = 'flex';
      banner.innerHTML = `
        <span>${escapeHtml(t('calc.quote.from_catalog', { name: localName(p) }))}</span>
        <button class="x" data-act="clear-banner" aria-label="Clear" title="Clear">×</button>`;
      banner.querySelector('[data-act="clear-banner"]').addEventListener('click', () => {
        currentBuildFromProductId = null;
        renderCartBanner();
      });
      return;
    }
  }
  banner.style.display = 'none';
}

/* ============================================================
   Printer Presets
   ============================================================ */
function renderPrinterPresets() {
  const select = $('#printerPreset');
  const prev = select.value;
  select.innerHTML = [
    `<option value="">${escapeHtml(t('calc.machine.no_preset'))}</option>`,
    ...printers.map(p => `<option value="${p.id}">${escapeHtml(p.name)}</option>`)
  ].join('');
  if (printers.find(p => p.id === prev)) select.value = prev;
  updateDeletePresetBtn();
}

function updateDeletePresetBtn() {
  const btn = $('#btnDeletePreset');
  if (btn) btn.style.display = $('#printerPreset').value ? 'inline-flex' : 'none';
}

function applyPreset(presetId) {
  const p = printers.find(x => x.id === presetId);
  if (!p) return;
  if (p.name)        $('#printerModel').value  = p.name;
  if (p.wearRate    !== undefined) $('#wearRate').value    = p.wearRate;
  if (p.powerDraw   !== undefined) $('#powerDraw').value   = p.powerDraw;
  if (p.elecRate    !== undefined) $('#elecRate').value    = p.elecRate;
  if (p.laborRate   !== undefined) $('#laborRate').value   = p.laborRate;
  if (p.failureRate !== undefined) $('#failureRate').value = p.failureRate;
  if (p.prepTime    !== undefined) $('#prepTime').value    = p.prepTime;
  if (p.postTime    !== undefined) $('#postTime').value    = p.postTime;
  updateGrandTotal();
}

// Auto-fill the calculator's printer fields from an assigned machine. A machine
// carries the printer identity (name/model) and the one printer-specific cost input
// it knows — power draw (from the printer catalog). Shop-wide rates (labour, failure,
// electricity) stay as they are; a preset can still override everything.
function applyMachineToCalculator(machineId) {
  const m = (typeof machines !== 'undefined' ? machines : []).find(x => x && x.id === machineId);
  if (!m) return;
  const nameEl = $('#printerModel');
  if (nameEl) nameEl.value = m.printerModelName || m.name || '';
  if (m.powerDraw != null && m.powerDraw !== '') { const el = $('#powerDraw'); if (el) el.value = m.powerDraw; }
  if (m.wearRate != null && m.wearRate !== '')   { const el = $('#wearRate');  if (el) el.value = m.wearRate; }
  if (typeof updateGrandTotal === 'function') updateGrandTotal();
}

function saveCurrentAsPreset() {
  const defaultName = $('#printerModel').value.trim();
  openFormModal({
    title: t('calc.machine.save_preset'),
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('calc.machine.preset'))}</label>
      <input type="text" id="_presetNameInput" value="${escapeHtml(defaultName)}"
             placeholder="${escapeHtml(t('calc.machine.preset_name_ph'))}">
    `,
    onMount(modal) { setTimeout(() => modal.querySelector('#_presetNameInput')?.focus(), 40); },
    async onSave(modal) {
      const name = modal.querySelector('#_presetNameInput').value.trim();
      if (!name) { toast(t('tpl.need_name'), 'error'); return false; }
      const existingIdx = printers.findIndex(p => p.name.toLowerCase() === name.toLowerCase());
      const preset = {
        id:          existingIdx >= 0 ? printers[existingIdx].id : uid('PRNTR'),
        name,
        wearRate:    num($('#wearRate').value,    0.75),
        powerDraw:   num($('#powerDraw').value,   150),
        elecRate:    num($('#elecRate').value,     0.18),
        laborRate:   num($('#laborRate').value,    90),
        failureRate: num($('#failureRate').value,  10),
        prepTime:    num($('#prepTime').value,     0.25),
        postTime:    num($('#postTime').value,     0.5),
      };
      if (existingIdx >= 0) printers[existingIdx] = preset;
      else printers.push(preset);
      saveAll();
      renderPrinterPresets();
      $('#printerPreset').value = preset.id;
      updateDeletePresetBtn();
      toast(t('calc.machine.preset_saved'), 'success');
      return true;
    }
  });
}

async function deleteCurrentPreset() {
  const val = $('#printerPreset').value;
  if (!val) return;
  const ok = await confirmModal(t('common.delete') + '?', { danger: true });
  if (!ok) return;
  printers = printers.filter(p => p.id !== val);
  saveAll();
  renderPrinterPresets();
  toast(t('calc.machine.preset_deleted'), 'success');
}

/* ============================================================
   Job Templates — save/load full job configs
   ============================================================ */
function renderJobTemplateSelect() {
  const sel = $('#jobTemplateSelect');
  if (!sel) return;
  const prev = sel.value;
  sel.innerHTML = [
    `<option value="">${escapeHtml(t('tpl.job_no_tpl') || 'No template')}</option>`,
    ...(settings.jobTemplates || []).map(tpl =>
      `<option value="${escapeHtml(tpl.id)}">${escapeHtml(tpl.name)}</option>`)
  ].join('');
  if ((settings.jobTemplates || []).find(t => t.id === prev)) sel.value = prev;
  const delBtn = $('#btnDeleteJobTemplate');
  if (delBtn) delBtn.style.display = sel.value ? 'inline-flex' : 'none';
}

function applyJobTemplate(tplId) {
  const tpl = (settings.jobTemplates || []).find(t => t.id === tplId);
  if (!tpl) return;
  if (tpl.margin      !== undefined && $('#margin'))      $('#margin').value      = tpl.margin;
  if (tpl.spoolCost   !== undefined && $('#spoolCost'))   $('#spoolCost').value   = tpl.spoolCost;
  if (tpl.spoolWeight !== undefined && $('#spoolWeight')) $('#spoolWeight').value = tpl.spoolWeight;
  if (tpl.printWeight !== undefined && $('#printWeight')) $('#printWeight').value = tpl.printWeight;
  if (tpl.printTime   !== undefined && $('#printTime'))   $('#printTime').value   = tpl.printTime;
  if (tpl.wearRate    !== undefined && $('#wearRate'))    $('#wearRate').value    = tpl.wearRate;
  if (tpl.powerDraw   !== undefined && $('#powerDraw'))   $('#powerDraw').value   = tpl.powerDraw;
  if (tpl.elecRate    !== undefined && $('#elecRate'))    $('#elecRate').value    = tpl.elecRate;
  if (tpl.laborRate   !== undefined && $('#laborRate'))   $('#laborRate').value   = tpl.laborRate;
  if (tpl.filamentId  !== undefined && $('#filamentSelect')) {
    $('#filamentSelect').value = tpl.filamentId;
    $('#filamentSelect').dispatchEvent(new Event('change'));
  }
  updateGrandTotal();
  toast(t('tpl.job_applied') || `Template "${tpl.name}" applied`, 'success', 2500);
}

function saveCurrentAsJobTemplate() {
  openFormModal({
    title: t('tpl.job_save') || 'Save Job Template',
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('tpl.job_name') || 'Template name')}</label>
      <input type="text" id="_jobTplNameInput" placeholder="${escapeHtml(t('tpl.job_name_ph') || 'e.g. Large PLA Print')}">
      <label style="margin-top:12px; font-size:11.5px; color:var(--text-muted);">${escapeHtml(t('tpl.job_captures') || 'Captures: margin, spool cost/weight, print weight, time, machine rates, material')}</label>`,
    onMount(modal) { setTimeout(() => modal.querySelector('#_jobTplNameInput')?.focus(), 40); },
    onSave(modal) {
      const name = (modal.querySelector('#_jobTplNameInput')?.value || '').trim();
      if (!name) { toast(t('tpl.need_name') || 'Name required', 'error'); return false; }
      if (!settings.jobTemplates) settings.jobTemplates = [];
      const existingIdx = settings.jobTemplates.findIndex(t => t.name.toLowerCase() === name.toLowerCase());
      const tpl = {
        id:          existingIdx >= 0 ? settings.jobTemplates[existingIdx].id : uid('JTPL'),
        name,
        margin:      $('#margin')?.value || '',
        spoolCost:   $('#spoolCost')?.value || '',
        spoolWeight: $('#spoolWeight')?.value || '',
        printWeight: $('#printWeight')?.value || '',
        printTime:   $('#printTime')?.value || '',
        wearRate:    $('#wearRate')?.value || '',
        powerDraw:   $('#powerDraw')?.value || '',
        elecRate:    $('#elecRate')?.value || '',
        laborRate:   $('#laborRate')?.value || '',
        filamentId:  $('#filamentSelect')?.value || '',
        savedAt:     new Date().toISOString(),
      };
      if (existingIdx >= 0) settings.jobTemplates[existingIdx] = tpl;
      else settings.jobTemplates.push(tpl);
      saveAll();
      renderJobTemplateSelect();
      $('#jobTemplateSelect').value = tpl.id;
      const delBtn = $('#btnDeleteJobTemplate');
      if (delBtn) delBtn.style.display = 'inline-flex';
      toast(t('tpl.job_saved') || `Template "${name}" saved`, 'success');
      return true;
    }
  });
}

async function deleteCurrentJobTemplate() {
  const sel = $('#jobTemplateSelect');
  if (!sel?.value) return;
  const ok = await confirmModal(t('common.delete') + '?', { danger: true });
  if (!ok) return;
  if (!settings.jobTemplates) return;
  settings.jobTemplates = settings.jobTemplates.filter(t => t.id !== sel.value);
  saveAll();
  renderJobTemplateSelect();
  toast(t('tpl.job_deleted') || 'Template deleted', 'success');
}

/* ============================================================
   Resin Exposure Profile Presets
   ============================================================ */
function renderResinProfiles() {
  const sel = $('#resinProfileSelect');
  if (!sel) return;
  const prev = sel.value;
  sel.innerHTML = [
    `<option value="">${escapeHtml(t('resin.no_profile') || 'No profile')}</option>`,
    ...(settings.resinProfiles || []).map(p =>
      `<option value="${escapeHtml(p.id)}">${escapeHtml(p.name)}</option>`)
  ].join('');
  if ((settings.resinProfiles || []).find(p => p.id === prev)) sel.value = prev;
  const delBtn = $('#btnDeleteResinProfile');
  if (delBtn) delBtn.style.display = sel.value ? 'inline-flex' : 'none';
}

function applyResinProfile(profileId) {
  const profile = (settings.resinProfiles || []).find(p => p.id === profileId);
  if (!profile) return;
  if (profile.layers      !== undefined && $('#resinLayers'))      $('#resinLayers').value      = profile.layers;
  if (profile.layerHeight !== undefined && $('#resinLayerHeight')) $('#resinLayerHeight').value = profile.layerHeight;
  if (profile.exposure    !== undefined && $('#resinExposure'))    $('#resinExposure').value    = profile.exposure;
  if (profile.baseLayers  !== undefined && $('#resinBaseLayers'))  $('#resinBaseLayers').value  = profile.baseLayers;
  if (profile.baseExposure!== undefined && $('#resinBaseExposure'))$('#resinBaseExposure').value= profile.baseExposure;
  toast(t('resin.profile_applied') || `Profile "${profile.name}" applied`, 'success', 2000);
}

function saveCurrentAsResinProfile() {
  openFormModal({
    title: t('resin.save_profile') || 'Save Resin Profile',
    sizeLg: false,
    saveLabel: t('common.save'),
    bodyHtml: `
      <label>${escapeHtml(t('resin.profile_name') || 'Profile name')}</label>
      <input type="text" id="_resinProfileNameInput" placeholder="${escapeHtml(t('resin.profile_name_ph') || 'e.g. Elegoo Standard 0.05mm')}">
      <div style="margin-top:10px; font-size:11.5px; color:var(--text-muted);">
        ${escapeHtml(t('resin.profile_captures') || 'Captures: layer count, height, exposure times, base settings')}
      </div>`,
    onMount(modal) { setTimeout(() => modal.querySelector('#_resinProfileNameInput')?.focus(), 40); },
    onSave(modal) {
      const name = (modal.querySelector('#_resinProfileNameInput')?.value || '').trim();
      if (!name) { toast(t('tpl.need_name') || 'Name required', 'error'); return false; }
      if (!settings.resinProfiles) settings.resinProfiles = [];
      const existingIdx = settings.resinProfiles.findIndex(p => p.name.toLowerCase() === name.toLowerCase());
      const profile = {
        id:           existingIdx >= 0 ? settings.resinProfiles[existingIdx].id : uid('RSNP'),
        name,
        layers:       $('#resinLayers')?.value      || '',
        layerHeight:  $('#resinLayerHeight')?.value || '0.05',
        exposure:     $('#resinExposure')?.value    || '',
        baseLayers:   $('#resinBaseLayers')?.value  || '',
        baseExposure: $('#resinBaseExposure')?.value|| '',
        savedAt:      new Date().toISOString(),
      };
      if (existingIdx >= 0) settings.resinProfiles[existingIdx] = profile;
      else settings.resinProfiles.push(profile);
      saveAll();
      renderResinProfiles();
      $('#resinProfileSelect').value = profile.id;
      const delBtn = $('#btnDeleteResinProfile');
      if (delBtn) delBtn.style.display = 'inline-flex';
      toast(t('resin.profile_saved') || `Profile "${name}" saved`, 'success');
      return true;
    }
  });
}

async function deleteCurrentResinProfile() {
  const sel = $('#resinProfileSelect');
  if (!sel?.value) return;
  const ok = await confirmModal(t('common.delete') + '?', { danger: true });
  if (!ok) return;
  if (!settings.resinProfiles) return;
  settings.resinProfiles = settings.resinProfiles.filter(p => p.id !== sel.value);
  saveAll();
  renderResinProfiles();
  toast(t('resin.profile_deleted') || 'Profile deleted', 'success');
}
/* ============================================================
   Quote Templates
   ============================================================ */
function renderQuoteTemplates() {
  const sel = $('#quoteTplSelect');
  const prev = sel.value;
  sel.innerHTML = [
    `<option value="">${escapeHtml(t('calc.tpl.none'))}</option>`,
    ...templates.map(tpl => `<option value="${tpl.id}">${escapeHtml(tpl.name)}</option>`)
  ].join('');
  if (templates.find(tpl => tpl.id === prev)) sel.value = prev;
  updateDeleteTplBtn();
}

function updateDeleteTplBtn() {
  const btn = $('#btnDeleteTpl');
  if (btn) btn.style.display = $('#quoteTplSelect').value ? 'inline-flex' : 'none';
}

async function loadQuoteTemplate() {
  const id = $('#quoteTplSelect').value;
  const tpl = templates.find(t => t.id === id);
  if (!tpl) { toast(t('calc.tpl.none'), 'error'); return; }
  if (currentBuild.length > 0) {
    const ok = await confirmModal(
      t('calc.tpl.overwrite_confirm') || 'Loading this template will replace your current build. Continue?',
      { danger: true, okText: t('calc.tpl.overwrite_ok') || 'Load template' }
    );
    if (!ok) return;
  }
  currentBuild = tpl.build.map(p => ({ ...p }));
  if (tpl.margin != null) $('#margin').value = tpl.margin;
  renderBuild();
  toast(t('calc.tpl.loaded'), 'success');
}

function saveQuoteTemplate() {
  if (currentBuild.length === 0) { toast(t('calc.tpl.empty'), 'error'); return; }
  openFormModal({
    title:     t('calc.tpl.save_title'),
    saveLabel: t('common.save'),
    bodyHtml:  `<label>${escapeHtml(t('calc.tpl.name_label'))}</label>
                <input type="text" id="tplNameInput" placeholder="${escapeHtml(t('calc.tpl.name_ph'))}" style="margin-top:6px;">`,
    onMount(modal) { modal.querySelector('#tplNameInput').focus(); },
    onSave() {
      const name = document.getElementById('tplNameInput').value.trim();
      if (!name) { toast(t('calc.tpl.name_ph'), 'error'); return false; }
      templates.push({
        id: uid('TPL'),
        name,
        build:  currentBuild.map(p => ({ ...p })),
        margin: clampPositive($('#margin').value)
      });
      saveAll();
      renderQuoteTemplates();
      toast(t('calc.tpl.saved'), 'success');
      return true;
    }
  });
}

async function deleteQuoteTemplate() {
  const id = $('#quoteTplSelect').value;
  if (!id) return;
  const ok = await confirmModal(t('common.delete') + '?', { danger: true });
  if (!ok) return;
  templates = templates.filter(tpl => tpl.id !== id);
  saveAll();
  renderQuoteTemplates();
  toast(t('calc.tpl.deleted'), 'success');
}
/**
 * What a spool costs a JOB, which is not what it cost the shop.
 *
 * A registered shop reclaims the tax it paid on the roll, so the tax is not
 * part of what a print consumes and charging it to the job would understate
 * every margin quoted from this form. A spool with no tax recorded — which is
 * every spool bought before Khayt asked — costs what it cost.
 */
function spoolCostBasis(item) {
  const profile = (typeof KhaytTax !== 'undefined' && typeof settings !== 'undefined')
    ? KhaytTax.profileFromSettings(settings) : null;
  const reclaims = !!(profile && profile.rates && profile.rates.length);
  return (typeof KhaytSpoolEdit !== 'undefined' && KhaytSpoolEdit.netCost)
    ? KhaytSpoolEdit.netCost(item, reclaims)
    : (+item.cost || 0);
}

function populateFilamentDropdown() {
  const select = $('#filamentSelect');
  const previous = select.value;
  /* THE SPOOL'S SIZE, NOT WHAT IS LEFT OF IT.
   *
   * `item.weight` is REMAINING grams — the inventory editor labels it
   * "Remaining (g)" and every completed job decrements it (inventory.js:1871,
   * :2146). The calculator's field says "Spool weight (g)" and computes
   * `(spoolCost / spoolWeight) x grams`, so quoting off a partly-used spool
   * valued the material at whatever fraction was left:
   *
   *     full spool (1000 g)   material  9.00   <- correct
   *     250 g left            material 36.00   <- 4x
   *     50 g left             material 180.00  <- 20x
   *
   * …for the same 100 g part off the same SAR 90 kilo. The shop over-quotes,
   * and its own margin report shows a cost that never existed.
   *
   * Every other cost site already divides by the spool SIZE — inventory.js:1251,
   * inventory.js:1673 (whose comment says "dividing by the *remaining* weight
   * valued every partly-used spool at full purchase cost") and
   * lib/po-audit.js:64. This dropdown was the one feeding it the wrong number. */
  select.innerHTML = inventory.map(item => `
    <option value="${item.id}" data-cost="${spoolCostBasis(item)}" data-weight="${Math.max(1, +item.spoolWeight || 1000)}" data-color="${escapeHtml(item.color || '#888888')}">
      ${escapeHtml(item.material)}${item.weight <= (item.reorderPoint ?? settings.lowStockThreshold) ? '  ⚠' : ''}
    </option>`).join('');
  if (inventory.find(i => i.id === previous)) {
    select.value = previous;
  }
  updateFilamentColorDot();
}

function updateFilamentColorDot() {
  const select = $('#filamentSelect');
  const dot    = $('#filColorDot');
  if (!select || !dot) return;
  const opt = select.options[select.selectedIndex];
  dot.style.background = opt?.dataset.color || '#888888';
}

function handleFilamentChange() {
  const select = $('#filamentSelect');
  const opt = select.options[select.selectedIndex];
  if (opt) {
    if (opt.dataset.cost)   $('#spoolCost').value   = opt.dataset.cost;
    if (opt.dataset.weight) $('#spoolWeight').value = opt.dataset.weight;
    updateGrandTotal();
  }
  updateFilamentColorDot();
  // Feature 4: Show print settings recommendation below filament select
  const item = select.value ? inventory.find(i => i.id === select.value) : null;
  let tipEl = $('#filamentPrintSettingsTip');
  if (!tipEl) {
    tipEl = document.createElement('div');
    tipEl.id = 'filamentPrintSettingsTip';
    tipEl.style.cssText = 'font-size:11.5px; color:var(--primary); margin-top:4px; padding:4px 8px; background:rgba(91,156,240,0.08); border-radius:4px; display:none;';
    select.parentNode?.insertBefore(tipEl, select.nextSibling) || select.after(tipEl);
  }
  if (item && (item.printTemp || item.bedTemp)) {
    const parts = [];
    if (item.printTemp) parts.push(`Print: ${item.printTemp}°C`);
    if (item.bedTemp)   parts.push(`Bed: ${item.bedTemp}°C`);
    if (item.maxSpeed)  parts.push(`Max: ${item.maxSpeed}mm/s`);
    tipEl.textContent = `🌡 ${escapeHtml(t('inv.print_settings'))}: ${parts.join(' / ')}`;
    tipEl.style.display = 'block';
  } else {
    tipEl.style.display = 'none';
  }

  // Feature 3: Populate spool picker if visible
  updateSpoolPicker();

  // Show/hide resin-specific fields
  updateResinFieldsVisibility();

  // Feature 5 (colour library): populate datalist for part colour field
  const colourDL = $('#partColourList');
  if (colourDL) {
    const item = $('#filamentSelect').value ? inventory.find(i => i.id === $('#filamentSelect').value) : null;
    const matKey = item ? item.material : null;
    const colours = matKey ? (settings.filamentColours?.[matKey] || []) : [];
    colourDL.innerHTML = colours.map(c => `<option value="${escapeHtml(c)}">`).join('');
  }
}

function updateSpoolPicker() {
  const sel = $('#filamentSelect');
  const spoolPicker = $('#spoolIdPicker');
  if (!spoolPicker) return;
  // Always show this specific spool plus others of same material type
  const selectedItem = sel.value ? inventory.find(i => i.id === sel.value) : null;
  if (!selectedItem) { spoolPicker.style.display = 'none'; return; }
  const sameMaterial = inventory.filter(i => i.material === selectedItem.material);
  spoolPicker.innerHTML = `<option value="">${escapeHtml(t('oe.select_spool'))}</option>` +
    sameMaterial.map(s => `<option value="${s.id}"${s.id === sel.value ? ' selected' : ''}>${escapeHtml(s.material)} — ${Math.round(s.weight)}g</option>`).join('');
  spoolPicker.style.display = sameMaterial.length > 0 ? '' : 'none';
}

function updateResinFieldsVisibility() {
  const fid = $('#filamentSelect')?.value;
  const isResin = fid ? (inventory.find(i => i.id === fid)?.materialType === 'resin') : false;
  const resinRow = $('#resinFieldsRow');
  if (resinRow) resinRow.style.display = isResin ? '' : 'none';
  renderResinProfiles();
  // Swap the printWeight label unit
  const pwUnitEl = $('#printWeightUnit');
  if (pwUnitEl) pwUnitEl.textContent = isResin ? 'mL' : (t('common.grams') || 'g');
}

  /**
   * AI assist (BYO Anthropic key, opt-in): describe a job in plain language; the
   * model fills the calculator form (the calculator still computes the price).
   * Fails safe — any error leaves the manual form untouched. On first use without
   * a key, prompts to paste one (stored encrypted, like other secrets).
   */
  async function aiQuoteAssist() {
    const ai = settings.ai || {};
    if (!ai.apiKey || !window.KhaytAiPrivacy.isFeatureEnabled(ai, 'quote')) {
      openFormModal({
        title: t('calc.ai_setup_title') || 'Set up AI assist',
        saveLabel: t('common.save') || 'Save',
        bodyHtml: `
          <p style="font-size:13px;color:var(--text-muted);">${escapeHtml(t('calc.ai_byok_note') || 'Uses your own Anthropic API key. Sent only to Anthropic; stored encrypted on this device.')}</p>
          <label>${escapeHtml(t('calc.ai_key') || 'Anthropic API key')}</label>
          <input type="password" id="aiKeyInput" value="${escapeHtml(secretInputValue(ai.apiKey))}" placeholder="sk-ant-...">
          <div style="display:flex;gap:8px;align-items:center;margin-top:8px;">
            <button type="button" class="btn small ghost" id="aiTestBtn">🔌 ${escapeHtml(t('calc.ai_test') || 'Test connection')}</button>
            <span id="aiTestResult" style="font-size:12.5px;"></span>
          </div>`,
        onMount(modal) {
          modal.querySelector('#aiTestBtn')?.addEventListener('click', async () => {
            const res = modal.querySelector('#aiTestResult');
            const typed = modal.querySelector('#aiKeyInput').value.trim();
            const key = typed || settings.ai?.apiKey || ai.apiKey || '';
            if (!key) { res.textContent = '✗ ' + (t('calc.ai_need_key') || 'Enter an API key'); res.style.color = 'var(--danger)'; return; }
            res.textContent = t('calc.ai_testing') || 'Testing…'; res.style.color = 'var(--text-muted)';
            try {
              const r = await khaytAiExtract({
                apiKey: key,
                model: (settings.ai && settings.ai.model) || 'claude-opus-5',
                task: 'quote',
                system: KhaytAiQuote.buildSystemContext(inventory),
                request: 'Estimate: one small 20mm PLA calibration cube.',
                schema: KhaytAiQuote.EXTRACTION_SCHEMA,
              });
              if (r && r.ok && r.draft) { res.textContent = '✓ ' + (t('calc.ai_test_ok') || 'Connection works'); res.style.color = 'var(--success)'; }
              else { res.textContent = '✗ ' + ((r && r.error) || 'failed'); res.style.color = 'var(--danger)'; }
            } catch (e) { res.textContent = '✗ ' + (e.message || e); res.style.color = 'var(--danger)'; }
          });
        },
        onSave(modal) {
          const typed = modal.querySelector('#aiKeyInput').value.trim();
          if (!typed && !ai.apiKey) { toast(t('calc.ai_need_key') || 'Enter an API key', 'error'); return false; }
          settings.ai = Object.assign({ model: 'claude-opus-5' }, settings.ai, { enabled: true, apiKey: secretInputSave(ai.apiKey, typed) });
          saveAll();
          toast(t('common.save') || 'Saved', 'success');
          return true;
        },
      });
      return;
    }
    openFormModal({
      title: t('calc.ai_quote') || 'AI quote',
      saveLabel: t('calc.ai_estimate') || 'Estimate',
      bodyHtml: `
        <label>${escapeHtml(t('calc.ai_describe') || 'Describe the job')}</label>
        <textarea id="aiDesc" rows="3" placeholder="${escapeHtml(t('calc.ai_desc_ph') || 'e.g. 50 keychains in blue PLA, ~15g each, by Thursday')}"></textarea>`,
      async onSave(modal) {
        const desc = modal.querySelector('#aiDesc').value.trim();
        if (!desc) { toast(t('calc.ai_need_desc') || 'Describe the job', 'error'); return false; }
        toast(t('calc.ai_thinking') || 'Estimating…', 'info');
        try {
          const transport = async (p) => {
            const r = await khaytAiExtract({ apiKey: settings.ai.apiKey, model: settings.ai.model, task: 'quote', system: p.system, request: p.request, schema: p.schema });
            if (!r || !r.ok) throw new Error((r && r.error) || 'AI error');
            return r.draft;
          };
          const client = KhaytAiQuote.createAiQuoteClient({ transport, model: settings.ai.model });
          const draft = await client.extract(desc, { materials: inventory });
          const { part, assumptions } = KhaytAiQuote.draftToPart(draft, { inventory, defaults: {} });
          // No /60 any more: `draftToPart` returns HOURS, like every other
          // part in the app. It used to hand back the model's minutes in a
          // field named `printTime`, and this line was the only thing standing
          // between that and a ninety-minute job quoted as ninety hours.
          if (part.printTime && $('#printTime')) $('#printTime').value = part.printTime.toFixed(2);
          if (part.printWeight && $('#printWeight')) $('#printWeight').value = part.printWeight.toFixed(1);
          if (typeof updateGrandTotal === 'function') updateGrandTotal();
          const note = assumptions.length ? '\n• ' + assumptions.join('\n• ') : '';
          toast((t('calc.ai_filled') || 'Form filled — review before sending') + note, 'success', 8000);
        } catch (e) {
          toast((t('calc.ai_failed') || 'AI estimate failed — fill manually') + ': ' + (e.message || e), 'error', 6000);
        }
        return true; // close either way; manual form remains usable (fail-safe)
      },
    });
  }

  /** AI shop assistant — ask questions grounded in the shop's own data. */
  async function openAiAssistant() {
    const ai = settings.ai || {};
    if (!ai.apiKey || !window.KhaytAiPrivacy.isFeatureEnabled(ai, 'assistant')) { toast(t('ai.assistant_need_key') || 'Enable AI assist (with your API key) in Settings first', 'error'); return; }
    if (typeof KhaytAiAssistant === 'undefined') { toast(t('common.feature_missing'), 'error'); return; }
    const ctx = KhaytAiAssistant.buildShopContext(collectStoreCollections(), { now: Date.now(), currency: (typeof currencySymbol === 'function' ? currencySymbol() : '') });
    const sugg = [
      t('ai.assistant_q1') || 'How much is outstanding?',
      t('ai.assistant_q2') || 'What is overdue or due soon?',
      t('ai.assistant_q3') || 'Which materials should I reorder?',
      t('ai.assistant_q4') || 'How does revenue compare to last month?',
    ];
    const convo = []; // [{ q, a }] — conversation memory for follow-ups
    const renderTranscript = (modal) => {
      const log = modal.querySelector('#aiChatLog');
      if (!convo.length) { log.innerHTML = `<p style="font-size:11.5px;color:var(--text-muted);margin:0;">${escapeHtml(t('ai.assistant_hint') || 'Answers come from your shop data — it won’t invent numbers.')}</p>`; return; }
      log.innerHTML = convo.map((turn) => `
        <div style="display:flex;justify-content:flex-end;margin:6px 0;"><div style="background:var(--primary);color:#fff;border-radius:12px 12px 2px 12px;padding:7px 11px;font-size:13px;max-width:85%;">${escapeHtml(turn.q)}</div></div>
        <div style="display:flex;justify-content:flex-start;margin:6px 0;"><div style="background:var(--surface-2);border:1px solid var(--border-soft);border-radius:12px 12px 12px 2px;padding:7px 11px;font-size:13.5px;max-width:85%;white-space:pre-wrap;">${escapeHtml(turn.a)}</div></div>`).join('');
      log.scrollTop = log.scrollHeight;
    };
    openFormModal({
      title: t('ai.assistant_title') || 'Ask Khayt AI',
      saveLabel: t('ai.assistant_ask') || 'Ask',
      bodyHtml: `
        <div id="aiChatLog" style="max-height:320px;overflow-y:auto;margin-bottom:10px;padding-right:4px;"></div>
        <input type="text" id="aiAskQ" placeholder="${escapeHtml(t('ai.assistant_ph') || 'Ask about orders, revenue, stock…')}">
        <div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:8px;">
          ${sugg.map((s) => `<button type="button" class="btn ghost small aiSug" data-q="${escapeHtml(s)}">${escapeHtml(s)}</button>`).join('')}
        </div>`,
      onMount(modal) {
        renderTranscript(modal);
        modal.querySelectorAll('.aiSug').forEach((b) => b.addEventListener('click', () => { modal.querySelector('#aiAskQ').value = b.dataset.q; }));
        setTimeout(() => modal.querySelector('#aiAskQ')?.focus(), 40);
      },
      async onSave(modal) {
        if (modal._aiBusy) return false; // one request at a time
        const input = modal.querySelector('#aiAskQ');
        const q = input.value.trim();
        const log = modal.querySelector('#aiChatLog');
        if (!q) { toast(t('ai.assistant_need_q') || 'Type a question first.', 'error'); return false; }
        modal._aiBusy = true;
        const saveBtn = modal.querySelector('.modal-save'); if (saveBtn) saveBtn.disabled = true;
        // Optimistically show the question + a thinking placeholder.
        convo.push({ q, a: t('ai.assistant_thinking') || 'Thinking…' });
        renderTranscript(modal); input.value = '';
        const turn = convo[convo.length - 1];
        try {
          const r = await khaytAiExtract({
            apiKey: ai.apiKey, model: ai.model || 'claude-opus-5', task: 'assistant',
            system: KhaytAiAssistant.buildAssistantSystem({ shopName: shopField('biz') || 'Khayt', lang: settings.lang }),
            request: KhaytAiAssistant.buildAssistantRequest(ctx, q, convo.slice(0, -1)),
            schema: KhaytAiAssistant.ASSISTANT_SCHEMA,
          });
          turn.a = (r && r.ok && r.draft) ? KhaytAiAssistant.pickAnswer(r.draft) : ('✗ ' + ((r && r.error) || 'AI request failed'));
        } catch (e) { turn.a = '✗ ' + (e.message || e); }
        modal._aiBusy = false;
        if (saveBtn) saveBtn.disabled = false;
        renderTranscript(modal);
        return false; // keep open for follow-up questions
      },
    });
  }

  const api = {
    saveBuildDraft,
    aiQuoteAssist,
    aiSuggestPrice,
    openAiAssistant,
    suggestedFailureRate,
    updateFailureRateHint,
    calculateLivePartCost,
    updateGrandTotal,
    snapshotPartFromForm,
    addPart,
    removePart,
    editPart,
    renderBuild,
    renderExtraLines,
    renderExtraMaterials,
    renderPriceTiers,
    renderCartBanner,
    renderPrinterPresets,
    updateDeletePresetBtn,
    applyPreset,
    applyMachineToCalculator,
    saveCurrentAsPreset,
    deleteCurrentPreset,
    renderJobTemplateSelect,
    applyJobTemplate,
    saveCurrentAsJobTemplate,
    deleteCurrentJobTemplate,
    renderResinProfiles,
    applyResinProfile,
    saveCurrentAsResinProfile,
    deleteCurrentResinProfile,
    renderQuoteTemplates,
    updateDeleteTplBtn,
    loadQuoteTemplate,
    saveQuoteTemplate,
    deleteQuoteTemplate,
    populateFilamentDropdown,
    updateFilamentColorDot,
    handleFilamentChange,
    updateSpoolPicker,
    updateResinFieldsVisibility,
  };

  Object.assign(global, api);
  global.KhaytBuild = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
