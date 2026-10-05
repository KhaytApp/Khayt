/* Converter · "Match to loaded spools" (KhaytConvSpools).
 *
 * The converter's slot table starts from the FILE: each colour keeps its slot
 * unless the maker moves it. This panel starts from the PRINTER: what is loaded
 * in each slot — reported by the machine (a U1's print_task_config, through the
 * poll cache), entered on the machine record, or picked here from the filament
 * inventory — and sends every file colour to the spool that looks most like it
 * (lib/spool-match.js, ported from bedready.io).
 *
 * It only ever produces what the converter already applies: a slot map, or a
 * merge through mergeToSlots, plus `spoolStrict` so a match the converter cannot
 * apply whole is refused and shown here, not saved as a file nothing moved in.
 *
 * Shared by Khayt and Bed Ready; reads the same globals converter.js does
 * (machines, machineStatusCache, inventory, t, escapeHtml).
 */
(function (global) {
  'use strict';

  const SM = () => global.KhaytSpoolMatch || null;
  const esc = (s) => (typeof escapeHtml === 'function' ? escapeHtml(String(s == null ? '' : s)) : String(s == null ? '' : s));
  function tr(key, fallback, vars) {
    try {
      const s = typeof t === 'function' ? t(key, vars) : '';
      if (s && s !== key) return s;
    } catch (_) { /* fall through */ }
    let out = fallback;
    if (vars) for (const k of Object.keys(vars)) out = out.split('{' + k + '}').join(String(vars[k]));
    return out;
  }
  function hexOf(v) {
    const m = /^#?([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(String(v || '').trim());
    return m ? '#' + m[1].toUpperCase() : null;
  }
  function sw(hex, size) {
    const h = hexOf(hex) || '#FFFFFF';
    return `<span class="cs-swatch" style="background:${h};width:${size}px;height:${size}px;" aria-hidden="true"></span>`;
  }

  /** Machines with something loaded: the printer's own report wins over what was typed. */
  function machineSources() {
    const list = (typeof machines !== 'undefined' && Array.isArray(machines)) ? machines : [];
    const cache = (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {};
    const out = [];
    for (const m of list) {
      if (!m || !m.id) continue;
      const live = cache[m.id] && Array.isArray(cache[m.id].loaded) ? cache[m.id].loaded : [];
      const typed = Array.isArray(m.loaded) ? m.loaded : [];
      const loaded = live.length ? live : typed;
      if (!loaded.some((s) => s && hexOf(s.hex || s.color))) continue;
      out.push({ id: 'm:' + m.id, name: m.name || m.id, live: !!live.length, loaded });
    }
    return out;
  }

  /** Inventory spools with a usable colour, for the per-slot pickers. */
  function stock() {
    const inv = (typeof inventory !== 'undefined' && Array.isArray(inventory)) ? inventory : [];
    return inv.filter((i) => i && hexOf(i.color));
  }
  function stockLabel(i) {
    return [i.brand, i.material, i.colourVariant || i.colorName].filter((x) => x && String(x).trim()).join(' · ') || hexOf(i.color);
  }

  /**
   * Mount the panel into a converter modal.
   * @param {HTMLElement} modal
   * @param {{ filaments:Array, flavour:string, targetId:()=>string, profile:(id:string)=>object|null,
   *           skip:()=>boolean }} ctx  `skip` → true when the target is Generic / another ecosystem.
   */
  function mount(modal, ctx) {
    const sm = SM();
    if (!modal || !sm || !ctx || !Array.isArray(ctx.filaments) || !ctx.filaments.length) return;
    let host = modal.querySelector('#convSpoolWrap');
    if (!host) {
      host = document.createElement('div');
      host.id = 'convSpoolWrap';
      host.className = 'conv-spools';
      const anchor = modal.querySelector('#convRemapWrap');
      if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(host, anchor.nextSibling);
      else (modal.querySelector('.modal-body') || modal).appendChild(host);
    }

    const sources = machineSources();
    const st = { source: sources.length ? sources[0].id : 'inv', picks: {}, edits: null, plan: null, active: false, refused: null };

    function slotCount() {
      const p = ctx.profile(ctx.targetId());
      return p && p.maxColors >= 1 ? p.maxColors : ctx.filaments.length;
    }
    function loadedNow() {
      if (st.source === 'inv') {
        const inv = stock();
        return Object.keys(st.picks).map((k) => {
          const it = inv.find((i) => i.id === st.picks[k]);
          return it ? { slot: +k, hex: hexOf(it.color), material: it.material || '', label: stockLabel(it) } : null;
        }).filter(Boolean);
      }
      const src = sources.find((s) => s.id === st.source);
      return src ? src.loaded : [];
    }
    function compute() {
      st.plan = sm.planSpoolMatch(ctx.filaments, loadedNow(), { slotCount: slotCount(), flavour: ctx.flavour, map: st.edits });
    }

    function refusalText(ref) {
      if (!ref) return '';
      if (ref.code === 'slot-past-end') return tr('conv.spool_refused_end', 'Slot {slot} is past this file\'s {n} colours, so the converter will not move colours there. Load that spool in slot {n} or lower, or assign it in your slicer.', { slot: ref.slot, n: ref.n });
      if (ref.code === 'slot-past-printer') return tr('conv.spool_refused_printer', 'Slot {slot} is past the {n} slots this printer has.', { slot: ref.slot, n: ref.n });
      return tr('conv.spool_refused_bad', 'This match cannot be applied.');
    }
    function warningText(w) {
      if (w.code === 'far') return tr('conv.spool_far', 'Colour {n} has no close spool (ΔE {de}).', { n: w.index + 1, de: Math.round(w.deltaE) });
      if (w.code === 'material') return tr('conv.spool_material', 'Colour {n} is {file} but slot {slot} holds {spool}. Check the material before printing.', { n: w.index + 1, file: w.file, spool: w.spool, slot: w.slot });
      if (w.code === 'beyond-target') return tr('conv.spool_beyond', 'Slots {slots} are past this printer\'s {n} slots and were left out.', { slots: w.slots.join(', '), n: w.n });
      if (w.code === 'no-spools') return tr('conv.spool_no_spools', 'No spools loaded. Pick a spool for at least one slot.');
      return '';
    }

    function sourceHtml() {
      const opts = sources.map((s) => `<option value="${esc(s.id)}"${st.source === s.id ? ' selected' : ''}>${esc(s.live
        ? tr('conv.spool_src_live', '{name} · reported by the printer', { name: s.name })
        : tr('conv.spool_src_typed', '{name} · as entered', { name: s.name }))}</option>`).join('');
      return `<label class="conv-spools-src">${esc(tr('conv.spool_source', 'Spools from'))}
        <select data-spool="source" class="conv-target">${opts}<option value="inv"${st.source === 'inv' ? ' selected' : ''}>${esc(tr('conv.spool_src_inventory', 'Pick from my filament inventory'))}</option></select></label>`;
    }
    function pickersHtml() {
      if (st.source !== 'inv') return '';
      const inv = stock();
      if (!inv.length) return `<p class="conv-note">${esc(tr('conv.spool_no_stock', 'Your filament inventory has no spools with a colour yet.'))}</p>`;
      const n = slotCount();
      const rows = [];
      for (let s = 0; s < n; s++) {
        const cur = st.picks[s] || '';
        const it = inv.find((i) => i.id === cur);
        rows.push(`<div class="conv-spools-pick">${sw(it ? it.color : null, 16)}<span>${esc(tr('conv.slot', 'Slot'))} ${s + 1}</span>
          <select data-spool="pick" data-slot="${s}" aria-label="${esc(tr('conv.slot', 'Slot') + ' ' + (s + 1))}">
            <option value="">${esc(tr('conv.spool_slot_empty', 'Empty'))}</option>
            ${inv.map((i) => `<option value="${esc(i.id)}"${i.id === cur ? ' selected' : ''}>${esc(stockLabel(i))}</option>`).join('')}
          </select></div>`);
      }
      return `<div class="conv-spools-picks">${rows.join('')}</div>`;
    }
    function tableHtml() {
      const p = st.plan;
      if (!st.active || !p) return '';
      if (!p.ok) return `<p class="conv-spools-warn" role="status">${esc(p.warnings.map(warningText).filter(Boolean).join(' '))}</p>`;
      const usableSlots = p.slots.usable.map((u, j) => (u ? j : -1)).filter((j) => j >= 0);
      const qLabel = { good: tr('conv.spool_q_good', 'Close'), fair: tr('conv.spool_q_fair', 'Near shade'), poor: tr('conv.spool_q_poor', 'No close spool') };
      const rows = p.rows.map((r) => `
        <tr class="conv-spools-row q-${r.quality}">
          <td>${sw(r.hex, 18)} <span class="conv-hex">${esc(r.hex)}</span>${r.material ? ` <span class="conv-spools-mat">${esc(r.material)}</span>` : ''}</td>
          <td aria-hidden="true">→</td>
          <td>${sw(r.spoolHex, 18)}
            <select data-spool="row" data-i="${r.index}" aria-label="${esc(tr('conv.spool_row_label', 'Slot for colour {n}', { n: r.index + 1 }))}">
              ${usableSlots.map((j) => `<option value="${j}"${j === r.slot ? ' selected' : ''}>${esc(tr('conv.slot', 'Slot'))} ${j + 1}${p.slots.labels[j] ? ' · ' + esc(p.slots.labels[j]) : (p.slots.materials[j] ? ' · ' + esc(p.slots.materials[j]) : '')}</option>`).join('')}
            </select>${r.materialMismatch ? ` <span class="conv-spools-matwarn" title="${esc(warningText({ code: 'material', index: r.index, file: r.material, spool: r.spoolMaterial, slot: r.slot + 1 }))}">⚠ ${esc(r.spoolMaterial)}</span>` : ''}</td>
          <td><span class="conv-spools-q q-${r.quality}"><span class="conv-spools-dot" aria-hidden="true"></span>${esc(qLabel[r.quality])} <span class="conv-de">ΔE ${esc(String(Math.round(r.deltaE)))}</span></span></td>
        </tr>`).join('');
      const req = p.request;
      let status = '';
      if (st.refused) status = `<p class="conv-spools-refused" role="alert">${esc(st.refused)}</p>`;
      else if (req.kind === 'refused') status = `<p class="conv-spools-refused" role="alert">${esc(refusalText(req.refusal))}</p>`;
      else if (req.kind === 'merge') status = `<p class="conv-spools-ok" role="status">${esc(tr('conv.spool_applies_merge', 'This file has {n} colours for {k} slots: converting merges them onto the loaded spools.', { n: p.rows.length, k: p.slots.hexes.length }))}</p>`;
      else if (req.kind === 'grow') status = `<p class="conv-spools-ok" role="status">${esc(tr('conv.spool_applies_grow', 'This file has {n} colours; converting adds slots up to slot {k} for the spools loaded there, each a copy of one of the file\'s filaments in the spool\'s colour.', { n: p.rows.length, k: Math.max.apply(null, p.map) + 1 }))}</p>`;
      else if (req.kind === 'slotMap') status = `<p class="conv-spools-ok" role="status">${esc(tr('conv.spool_applies_map', 'Converting will use this slot assignment.'))}</p>`;
      else status = `<p class="conv-spools-ok" role="status">${esc(tr('conv.spool_none', 'Every colour is already in the slot of its spool — nothing to move.'))}</p>`;
      const warns = p.warnings.filter((w) => w.code !== 'far').map(warningText).filter(Boolean);
      const far = p.far.length ? [tr('conv.spool_far_count', 'Colours without a close spool: {n}.', { n: p.far.length })] : [];
      return `<table class="conv-spools-table">
          <thead><tr><th>${esc(tr('conv.spool_col_file', 'File colour'))}</th><th></th><th>${esc(tr('conv.spool_col_spool', 'Slot · spool'))}</th><th>${esc(tr('conv.spool_col_match', 'Match'))}</th></tr></thead>
          <tbody>${rows}</tbody></table>
        ${warns.concat(far).map((w) => `<p class="conv-spools-warn">⚠ ${esc(w)}</p>`).join('')}
        ${status}`;
    }

    function render() {
      if (ctx.skip()) { host.innerHTML = ''; host.hidden = true; return; }
      host.hidden = false;
      if (st.active) compute();
      host.innerHTML = `
        <div class="conv-spools-head">
          <div class="conv-spools-title">${esc(tr('conv.spool_title', 'Match to loaded spools'))}</div>
          <div class="conv-spools-hint">${esc(sources.length
            ? tr('conv.spool_hint', 'The printer is already loaded? Send every colour to the spool that looks most like it. Several colours may share a spool.')
            : tr('conv.spool_no_source', 'None of your machines lists what is loaded. Pick a spool from your inventory for each slot, or skip this.'))}</div>
        </div>
        <div class="conv-spools-controls">${sourceHtml()}
          <button type="button" class="btn small" data-spool="match">${esc(tr('conv.spool_match', 'Match'))}</button>
          ${st.active ? `<button type="button" class="btn small ghost" data-spool="clear">${esc(tr('conv.spool_clear', 'Don\'t match'))}</button>` : ''}
        </div>
        ${pickersHtml()}
        ${tableHtml()}`;
    }

    // The converter's own previews that depend on the match (the PrusaSlicer project plan).
    const changed = () => { if (typeof ctx.onChange === 'function') { try { ctx.onChange(); } catch (_) { /* preview only */ } } };
    host.addEventListener('change', (e) => {
      const el = e.target;
      const kind = el && el.getAttribute('data-spool');
      st.refused = null;
      if (kind === 'source') { st.source = el.value; st.edits = null; render(); }
      else if (kind === 'pick') {
        const s = +el.getAttribute('data-slot');
        if (el.value) st.picks[s] = el.value; else delete st.picks[s];
        st.edits = null; render();
      } else if (kind === 'row') {
        const i = +el.getAttribute('data-i');
        st.edits = (st.plan && st.plan.map ? st.plan.map.slice() : []);
        st.edits[i] = parseInt(el.value, 10);
        render();
      }
      changed();
    });
    host.addEventListener('click', (e) => {
      const b = e.target && e.target.closest && e.target.closest('[data-spool]');
      if (!b || b.tagName !== 'BUTTON') return;
      st.refused = null;
      if (b.getAttribute('data-spool') === 'match') { st.active = true; st.edits = null; render(); }
      else if (b.getAttribute('data-spool') === 'clear') { st.active = false; st.plan = null; st.edits = null; render(); }
      changed();
    });
    // The target decides the slot count; the converter re-renders its own table on change,
    // and a catalogue printer's profile arrives a moment later — follow both.
    const sel = modal.querySelector('#convTarget');
    if (sel) sel.addEventListener('change', () => { st.edits = null; st.refused = null; setTimeout(render, 0); setTimeout(render, 1500); });

    // What onSave reads: the request to send, or the refusal to show instead of converting.
    modal._spoolState = () => {
      if (!st.active || ctx.skip()) return { active: false };
      compute();
      const p = st.plan;
      if (!p || !p.ok) return { active: true, refusal: p ? p.warnings.map(warningText).filter(Boolean).join(' ') : '' };
      if (p.request.kind === 'refused') { render(); return { active: true, refusal: refusalText(p.request.refusal) }; }
      if (p.request.kind === 'none') return { active: true, request: p.request.slotSpools ? { slotMap: null, slotSpools: p.request.slotSpools, spoolStrict: true } : null };
      return { active: true, request: { slotMap: p.request.slotMap || null, mergeToSlots: !!p.request.mergeToSlots, spoolMerge: p.request.spoolMerge || null,
        growToSlots: p.request.growToSlots || null, slotSpools: p.request.slotSpools || null, spoolStrict: true } };
    };
    // The converter refused the match after all (a model it could not read, settings it cannot
    // reorder): say so here, next to the table, as well as in the toast.
    modal._spoolRefused = (msg) => { st.refused = String(msg || ''); render(); };
    render();
  }

  global.KhaytConvSpools = { mount, machineSources };
})(typeof window !== 'undefined' ? window : globalThis);
