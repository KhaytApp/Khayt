/* ============================================================
   BED READY — branded home hero.
   Replaces the shared Khayt dashboard with a lean, on-brand maker
   home (echoing bedready.io): geometric headline, sticker badges,
   and quick-action cards into the maker tools. Bed Ready flavor only.

   Mechanism: dashboard.js declares `function renderDashboard()`, which
   initialRender() (app-boot.js) and tab switches call by bareword — a
   global binding. This file is loaded AFTER dashboard.js and BEFORE
   app-boot.js, so reassigning `window.renderDashboard` here swaps in the
   Bed Ready home for every call. Guarded on the flavor marker so it can
   never affect Khayt.

   Self-heal: during boot the studio shell (initAppShell → KhaytBedReadyUI)
   re-mounts and empties #dashboardContent AFTER initialRender's first
   render, leaving the landing dashboard blank. A short-lived observer +
   poll re-renders the home into the live node whenever the dashboard tab
   is active and empty, until it sticks. Tab switches thereafter go
   through renderDashboard (this override) as normal.
   ============================================================ */
(function () {
  if (typeof document === 'undefined' || document.documentElement.dataset.app !== 'bedready') return;

  // Bespoke drafting-style icon (Cyanotype Draft, Phase 2) with an emoji fallback if the icon
  // set hasn't loaded. Returns inline SVG markup for a home quick-action tile.
  function ico(name, fallback) {
    return (window.BedReadyIcons && window.BedReadyIcons.get(name)) || (fallback || '');
  }

  // ── Copy overrides ─────────────────────────────────────────────────────────
  // Rename Khayt / business terms to Bed Ready maker terms across every language.
  // i18n's STRINGS table aliases globalThis.KhaytLocales, and this renderer runs
  // in its own process, so mutating it here re-labels nav + topbar + placeholders
  // at once and never touches Khayt. Applied to all loaded locales (English maker
  // wording is fine for these product-specific terms).
  try {
    var LOC = (typeof globalThis !== 'undefined' && globalThis.KhaytLocales) || (typeof window !== 'undefined' && window.KhaytLocales) || null;
    if (LOC) {
      var OV = {
        'tab.queue': 'Print Queue',
        'queue.title': 'Print queue',
        'kan.search_ph': 'Filter jobs…',
        'kan.orders': 'jobs',
        // "QC" reads as a business/factory term; a solo maker still inspects a print,
        // so relabel to "Inspect" (keeps the post→qc→completed board flow intact). The
        // "Delivered" column is hidden in bedready-theme.css — it only ever fills from a
        // business deliveredAt stamp (customer hand-off) that Bed Ready never sets.
        'kan.col_qc': 'Inspect',
        'slicer.slice_btn': '🧩 Slice for exact weight',
        'tab.sub.settings': 'Preferences, inventory & data',
        'set.biz_ar': 'Studio name (Arabic)',
        'set.logo': 'Logo',
        'set.biz_identity': 'Studio identity',
        'waiting.title': 'Job intake',
        'mach.empty': 'No printers added yet — add one to assign jobs to a machine.',
        'queue.empty': 'No jobs here.',
        'calc.quote.empty': 'No parts in this project yet. The live preview below reflects the current form.',
        'calc.quote.add_part': '+ Add part to project',
        'set.tagline_ph': 'e.g. Multi-colour minis & functional prints',
        // Updater copy that bakes in the Khayt product name.
        'upd.ready_version': 'Bed Ready {version} will install after restart.',
        'set.beta_updates': 'Include Bed Ready beta pre-releases when checking for updates',
        // Settings card holds both language + theme selects.
        'set.lang_theme_head': 'Language & Theme',
      };
      Object.keys(LOC).forEach(function (lang) {
        if (LOC[lang] && typeof LOC[lang] === 'object') {
          Object.keys(OV).forEach(function (k) { LOC[lang][k] = OV[k]; });
        }
      });
    }
  } catch (e) { /* non-fatal */ }

  // Maker stats — computed from completed prints (grams used, spend, top
  // materials). Reuses the same per-part fields the shared analytics use, but
  // framed for a hobbyist (no revenue/margin). Returns '' when there's nothing
  // printed yet so the home stays clean on a fresh install.
  function makerStatsHtml() {
    var log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    var inv = (typeof inventory !== 'undefined' && Array.isArray(inventory)) ? inventory : [];
    var done = log.filter(function (o) { return KhaytOrderStatus.isFinished(o); });
    if (done.length === 0) return '';

    var grams = 0, spend = 0;
    var byMat = {};
    done.forEach(function (o) {
      (o.parts || []).forEach(function (p) {
        var pw = (+p.printWeight || 0) + (+p.supportWeight || 0);
        if (pw <= 0) return;
        grams += pw;
        var spoolC = +p.spoolCost || 0, spoolW = Math.max(1, +p.spoolWeight || 1000);
        spend += (spoolC / spoolW) * pw;
        var fil = inv.find(function (i) { return i.id === p.filamentId; });
        var label = p.material || (fil && fil.material) || 'Filament';
        var color = (fil && fil.color) || '#888';
        if (!byMat[label]) byMat[label] = { label: label, color: color, grams: 0 };
        byMat[label].grams += pw;
      });
    });

    var top = Object.keys(byMat).map(function (k) { return byMat[k]; })
      .sort(function (a, b) { return b.grams - a.grams; }).slice(0, 4);
    var esc = (typeof escapeHtml === 'function') ? escapeHtml : function (s) { return s; };
    var money = (typeof fmtPrice === 'function') ? fmtPrice(spend) : String(Math.round(spend));
    var kg = grams >= 1000 ? (grams / 1000).toFixed(grams >= 10000 ? 0 : 1) + ' kg' : Math.round(grams) + ' g';

    var stat = function (val, lab) {
      return '<div class="br-stat"><div class="br-stat-val">' + val + '</div><div class="br-stat-lab">' + lab + '</div></div>';
    };
    var topHtml = top.map(function (m) {
      var pct = grams > 0 ? Math.round(m.grams / grams * 100) : 0;
      var g = m.grams >= 1000 ? (m.grams / 1000).toFixed(1) + ' kg' : Math.round(m.grams) + ' g';
      return '<div class="br-mat-row">'
        + '<span class="br-mat-dot" style="background:' + esc(String(m.color)) + '"></span>'
        + '<span class="br-mat-name">' + esc(m.label) + '</span>'
        + '<span class="br-mat-bar"><span style="width:' + pct + '%"></span></span>'
        + '<span class="br-mat-g">' + g + '</span>'
        + '</div>';
    }).join('');

    return [
      '<section class="br-stats">',
        '<div class="br-stats-head">Your printing so far</div>',
        '<div class="br-stat-row">',
          stat(String(done.length), done.length === 1 ? 'print done' : 'prints done'),
          stat(esc(kg), 'filament used'),
          stat(esc(money), 'material spend'),
        '</div>',
        top.length ? '<div class="br-mat-list">' + topHtml + '</div>' : '',
      '</section>',
    ].join('');
  }

  // Energy & impact — cumulative electricity, its cost, an estimated carbon
  // footprint, and filament wasted. All from data already stored on completed
  // prints (parts carry printTime / powerDraw / elecRate) plus the Waste Log —
  // no new inputs. Hidden until there's something to show.
  function energyStatsHtml() {
    var log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    var done = log.filter(function (o) { return KhaytOrderStatus.isFinished(o); });
    var kwh = 0, energyCost = 0;
    done.forEach(function (o) {
      (o.parts || []).forEach(function (p) {
        var pt = Math.max(0, +p.printTime || 0);
        var partKwh = pt * (Math.max(0, +p.powerDraw || 0) / 1000);
        kwh += partKwh;
        energyCost += partKwh * Math.max(0, +p.elecRate || 0);
      });
    });
    var wasteG = (typeof wasteLog !== 'undefined' && Array.isArray(wasteLog))
      ? wasteLog.reduce(function (s, w) { return s + (+w.weight || 0); }, 0) : 0;
    if (kwh <= 0 && wasteG <= 0) return '';

    var GRID_KG_PER_KWH = 0.42; // global grid average CO2e; labelled "est."
    var co2 = kwh * GRID_KG_PER_KWH;
    var esc = (typeof escapeHtml === 'function') ? escapeHtml : function (s) { return s; };
    var kwhStr = kwh >= 100 ? Math.round(kwh) : kwh.toFixed(1);
    var co2Str = co2 >= 10 ? Math.round(co2) + ' kg' : co2.toFixed(1) + ' kg';
    var wasteStr = wasteG >= 1000 ? (wasteG / 1000).toFixed(1) + ' kg' : Math.round(wasteG) + ' g';
    var cost = (typeof fmtPrice === 'function') ? fmtPrice(energyCost) : String(Math.round(energyCost));
    var stat = function (val, lab) {
      return '<div class="br-stat"><div class="br-stat-val">' + val + '</div><div class="br-stat-lab">' + lab + '</div></div>';
    };
    var cells = [];
    if (kwh > 0) {
      cells.push(stat(esc(kwhStr) + ' <span class="br-stat-unit">kWh</span>', 'electricity'));
      cells.push(stat(esc(cost), 'energy cost'));
      cells.push(stat('~' + esc(co2Str), 'CO₂e (est.)'));
    }
    if (wasteG > 0) cells.push(stat(esc(wasteStr), 'filament wasted'));

    return [
      '<section class="br-stats">',
        '<div class="br-stats-head">Energy &amp; impact</div>',
        '<div class="br-stat-row">', cells.join(''), '</div>',
      '</section>',
    ].join('');
  }

  function homeHtml() {
    return [
      '<div class="br-home">',
        '<section class="br-hero">',
          '<p class="br-hero-eyebrow">Bed Ready · Maker Studio</p>',
          '<h1>3D-print files, ready for <span class="accent">any bed</span>.</h1>',
          '<p class="br-hero-sub">Convert, recolour and queue your prints — agnostic by design, nothing ever uploaded.</p>',
          '<div class="br-stickers">',
            '<span class="br-sticker spectrum">full-spectrum</span>',
            '<span class="br-sticker">any bed</span>',
            '<span class="br-sticker orange">nothing uploaded</span>',
            '<span class="br-sticker">built for makers</span>',
          '</div>',
          '<div class="br-actions">',
            '<button type="button" class="br-action" data-go="converter-tab"><span class="ico" aria-hidden="true">' + ico('convert', '🔄') + '</span><span class="t"><b>Convert a file</b><span>3MF / STL → any printer</span></span></button>',
            '<button type="button" class="br-action orange" data-go="colorstudio-tab"><span class="ico" aria-hidden="true">' + ico('colour', '🎨') + '</span><span class="t"><b>Colour Studio</b><span>plan multi-colour prints</span></span></button>',
            '<button type="button" class="br-action" data-go="queue-tab"><span class="ico" aria-hidden="true">' + ico('queue', '▤') + '</span><span class="t"><b>Print queue</b><span>track your jobs</span></span></button>',
          '</div>',
        '</section>',
        makerStatsHtml(),
        energyStatsHtml(),
        kitsHtml(),
        '<div class="br-home-grid">',
          '<button type="button" class="br-action" data-go="inventory-tab"><span class="ico" aria-hidden="true">' + ico('spool', '⬡') + '</span><span class="t"><b>Inventory</b><span>filament & stock</span></span></button>',
          '<button type="button" class="br-action" data-go="printfiles-tab"><span class="ico" aria-hidden="true">' + ico('cube', '🧊') + '</span><span class="t"><b>Print files</b><span>your model library</span></span></button>',
          '<button type="button" class="br-action" data-go="calculator-tab"><span class="ico" aria-hidden="true">' + ico('calc', '◎') + '</span><span class="t"><b>Calculator</b><span>cost per print</span></span></button>',
          '<button type="button" class="br-action" data-library="1"><span class="ico" aria-hidden="true">' + ico('cloud', '☁️') + '</span><span class="t"><b>My BedReady library</b><span>sync your saved designs</span></span></button>',
          '<button type="button" class="br-action" data-filaments="1"><span class="ico" aria-hidden="true">' + ico('nozzle', '🧵') + '</span><span class="t"><b>Filament profiles</b><span>add to your slicer</span></span></button>',
          '<button type="button" class="br-action" data-drylog="1"><span class="ico" aria-hidden="true">' + ico('droplet', '💧') + '</span><span class="t"><b>Filament care</b><span>drying &amp; storage log</span></span></button>',
        '</div>',
      '</div>',
    ].join('');
  }

  // Needle-settle (Cyanotype Draft motion signature): the hero stat figures
  // count up and ease to rest like an analog gauge needle settling, rather than
  // snapping in. Animates only the numeric text node so unit spans (kWh, kg) are
  // preserved, restores the exact original string at the end, and no-ops under
  // "reduce motion". Contained to the home stats panel — not every number counts.
  function settleStatEl(el, delay) {
    var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null, false);
    var node, tn = null;
    while ((node = walker.nextNode())) { if (/\d/.test(node.nodeValue)) { tn = node; break; } }
    if (!tn) return;
    var raw = tn.nodeValue;
    var m = raw.match(/\d[\d,]*\.?\d*/);
    if (!m) return;
    var numStr = m[0];
    var pre = raw.slice(0, m.index), post = raw.slice(m.index + numStr.length);
    var target = parseFloat(numStr.replace(/,/g, ''));
    if (!isFinite(target) || target <= 0) return;
    var dot = numStr.indexOf('.');
    var decimals = dot >= 0 ? numStr.length - dot - 1 : 0;
    var useComma = numStr.indexOf(',') >= 0 || target >= 1000;
    var fmt = function (v) {
      var s = v.toFixed(decimals);
      if (useComma) { var p = s.split('.'); p[0] = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ','); s = p.join('.'); }
      return s;
    };
    var dur = 640, startTs = null;
    tn.nodeValue = pre + fmt(0) + post;
    var frame = function (ts) {
      if (startTs === null) startTs = ts;
      var t = Math.min(1, (ts - startTs) / dur);
      var eased = 1 - Math.pow(1 - t, 3); // ease-out cubic — needle settling to rest
      tn.nodeValue = pre + fmt(target * eased) + post;
      if (t < 1) requestAnimationFrame(frame);
      else tn.nodeValue = raw; // restore exact original formatting
    };
    setTimeout(function () { requestAnimationFrame(frame); }, delay || 0);
  }

  function settleStats(el) {
    try {
      if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    } catch (e) { /* matchMedia absent — fall through and animate */ }
    var vals = el.querySelectorAll('.br-stat-val');
    for (var i = 0; i < vals.length; i++) settleStatEl(vals[i], i * 70);
  }

  /**
   * Kits — several prints that are one object.
   *
   * The maker case this exists for: a figure printed as a head, a body and two
   * legs is four separate jobs, and nothing said they belonged together.
   *
   * Khayt creates kits from the orders list's batch bar. Bed Ready ships no
   * orders list at all (logs-tab is not in bedready.html), so the same job is
   * done here: finished prints that are not in a kit are offered with a
   * checkbox, and naming them makes one. No modal — a tray on the home is fewer
   * moving parts than a dialog, and this is a screen the maker already reads.
   *
   * Every total is shown with the count of jobs behind it, because a total that
   * quietly omits an unmeasured job is the bug lib/print-kits.js exists to stop.
   */
  var KIT_TRAY_MAX = 12;   // recent unfiled prints offered at once

  function kitsHtml() {
    if (typeof KhaytPrintKits === 'undefined') return '';
    // Declared locally, the way this file already does at makerStatsHtml() —
    // `esc` is not file-scoped here and `tr` does not exist in this module at
    // all. Both fall back rather than throw: a missing helper must not take the
    // whole home down.
    var esc = (typeof escapeHtml === 'function') ? escapeHtml
      : function (v) { return String(v).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
    var tr = function (key, fallback) {
      try { return (typeof t === 'function' && t(key)) || fallback; } catch (_) { return fallback; }
    };
    var log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
    var defs = (typeof settings !== 'undefined' && settings && Array.isArray(settings.kits)) ? settings.kits : [];
    var g = KhaytPrintKits.groupByKit(log, defs);
    var done = g.ungrouped.filter(function (o) { return KhaytOrderStatus.isFinished(o); });
    // The tray has to appear for a SINGLE unfiled print once a kit exists, or a
    // part finished after the kit was made can never be added to it — which is
    // the ordinary case: you group what you have, then the last part finishes.
    // Two are required only on a fresh shop, so a lone first print is not noise.
    var canGroup = done.length >= (g.kits.length ? 1 : 2);
    if (!g.kits.length && !canGroup) return '';

    var rows = g.kits.map(function (k) {
      var r = k.rollup;
      var partial = r.measuredTime < r.jobs
        ? ' <span style="color:var(--warning);">(' + r.measuredTime + '/' + r.jobs + ' ' + esc(tr('kit.measured', 'measured')) + ')</span>' : '';
      var money = r.mixedCurrency ? esc(tr('kit.mixed_currency', 'mixed currencies')) : (r.cost + ' ' + esc(r.currency || ''));
      var delta = (k.accuracy && k.accuracy.time !== null)
        ? ' <span style="color:var(--text-muted);">· ' + (k.accuracy.time > 0 ? '+' : '') + k.accuracy.time + '% ' + esc(tr('kit.vs_estimate', 'vs estimate')) + '</span>' : '';
      return '<div class="br-kit-row" style="display:flex;align-items:center;gap:9px;flex-wrap:wrap;padding:6px 0;border-top:1px solid var(--border-soft);">'
        + '<strong>🧩 ' + esc(k.name) + '</strong>'
        + '<span style="font-size:12px;color:var(--text-dim);">' + r.jobs + ' ' + esc(tr('kit.jobs', 'jobs')) + partial + '</span>'
        + '<span style="font-size:12px;font-family:var(--font-num);">' + r.actualHours + ' h · ' + r.actualGrams + ' g · ' + money + '</span>'
        + delta
        + '<span style="flex:1;"></span>'
        + '<button type="button" class="btn ghost small" data-kit-rename="' + esc(k.id) + '">' + esc(tr('kit.rename', 'Rename')) + '</button>'
        + '<button type="button" class="btn ghost small" data-kit-disband="' + esc(k.id) + '">' + esc(tr('kit.disband', 'Disband')) + '</button>'
        + '</div>';
    }).join('');

    var tray = '';
    if (canGroup) {
      var shown = done.slice(0, KIT_TRAY_MAX);
      tray = '<div style="margin-top:10px;padding-top:9px;border-top:1px solid var(--border-soft);">'
        + '<div style="font-size:12px;color:var(--text-muted);margin-bottom:6px;">' + esc(tr('kit.tray_hint', 'Tick the prints that are one object')) + '</div>'
        + shown.map(function (o) {
            return '<label style="display:inline-flex;align-items:center;gap:5px;margin:0 10px 6px 0;font-size:12.5px;">'
              + '<input type="checkbox" class="br-kit-pick" value="' + esc(o.id) + '" style="width:auto;margin:0;">'
              + esc(o.project || o.id) + '</label>';
          }).join('')
        // Said out loud rather than silently truncating: a tray that shows 12 of
        // 30 and says nothing reads as "these are all your unfiled prints".
        + (done.length > shown.length
            ? '<div style="font-size:11.5px;color:var(--text-muted);margin-bottom:6px;">'
              + esc(tr('kit.tray_more', 'Showing the {n} most recent.').replace('{n}', String(shown.length))) + '</div>'
            : '')
        + '<div style="display:flex;gap:7px;align-items:center;flex-wrap:wrap;">'
        + '<input type="text" id="brKitName" placeholder="' + esc(tr('kit.name_ph', 'Kit name')) + '" style="max-width:190px;">'
        + '<button type="button" class="btn small primary" data-kit-add="1">' + esc(tr('kit.add_to', 'Add to kit')) + '</button>'
        + '</div></div>';
    }

    return '<section class="br-card" style="padding:12px 14px;margin-bottom:12px;">'
      + '<div style="font-weight:600;font-size:13px;">' + esc(tr('kit.card_title', 'Kits')) + '</div>'
      + rows + tray + '</section>';
  }

  /** Create a kit from the ticked prints, or disband one. */
  function wireKits(el) {
    var add = el.querySelector('[data-kit-add]');
    if (add) {
      add.addEventListener('click', function () {
        var picked = [].slice.call(el.querySelectorAll('.br-kit-pick:checked')).map(function (c) { return c.value; });
        var nameEl = el.querySelector('#brKitName');
        var name = String((nameEl && nameEl.value) || '').trim();
        if (!picked.length || !name) return;          // nothing ticked, or unnamed
        if (!Array.isArray(settings.kits)) settings.kits = [];
        // Reuse a kit of the same name rather than splitting the rollup in two.
        // The rule lives in lib/print-kits.js so this and the print log cannot
        // disagree about what a typed name means — they had two copies of it,
        // and the copies had already drifted over what to do about a clash.
        var K = (typeof KhaytPrintKits !== 'undefined') ? KhaytPrintKits : null;
        var resolved = K
          ? K.resolveKitName(name, settings.kits, function () { return 'KIT-' + Math.random().toString(36).slice(2, 11); })
          : null;
        var kit = resolved
          ? settings.kits.filter(function (k) { return String(k.id) === resolved.id; })[0]
          : settings.kits.filter(function (k) { return String(k.name).trim().toLowerCase() === name.toLowerCase(); })[0];
        if (!kit) {
          kit = resolved
            ? { id: resolved.id, name: resolved.name }
            : { id: 'KIT-' + Math.random().toString(36).slice(2, 11), name: name };
          settings.kits.push(kit);
        }
        picked.forEach(function (id) {
          var o = printLog.filter(function (x) { return x.id === id; })[0];
          if (o) o.kitId = kit.id;
        });
        saveAll();
        if (typeof renderDashboard === 'function') renderDashboard();
      });
    }
    el.querySelectorAll('[data-kit-rename]').forEach(function (b) {
      b.addEventListener('click', function () {
        var id = b.getAttribute('data-kit-rename');
        var kits = Array.isArray(settings.kits) ? settings.kits : [];
        var cur = kits.filter(function (k) { return k.id === id; })[0];
        var name = String(prompt('Kit name', cur ? cur.name : '') || '').trim();
        if (!name || (cur && name === cur.name)) return;
        // Refuse a name another kit holds rather than merging into it — that
        // would move somebody else's jobs on the strength of a typo.
        var clash = kits.filter(function (k) {
          return k.id !== id && String(k.name).trim().toLowerCase() === name.toLowerCase();
        })[0];
        if (clash) return;
        // An orphan has no definition; naming it writes one back, so jobs are
        // never stuck in something unnameable.
        if (cur) cur.name = name;
        else settings.kits = kits.concat([{ id: id, name: name }]);
        saveAll();
        if (typeof renderDashboard === 'function') renderDashboard();
      });
    });
    el.querySelectorAll('[data-kit-disband]').forEach(function (b) {
      b.addEventListener('click', function () {
        var id = b.getAttribute('data-kit-disband');
        // Unfiles the jobs. It never removes a print.
        printLog.forEach(function (o) { if (o.kitId === id) delete o.kitId; });
        settings.kits = (settings.kits || []).filter(function (k) { return k.id !== id; });
        // …and any kit this emptied along the way, so the list does not collect
        // names attached to nothing. Same rule the print log applies.
        if (typeof KhaytPrintKits !== 'undefined') {
          var dead = KhaytPrintKits.emptyKitIds(printLog, settings.kits);
          if (dead.length) {
            settings.kits = settings.kits.filter(function (k) { return dead.indexOf(String(k.id)) === -1; });
          }
        }
        saveAll();
        if (typeof renderDashboard === 'function') renderDashboard();
      });
    });
  }

  function fill(el) {
    el.innerHTML = homeHtml();
    settleStats(el);
    wireKits(el);
    el.querySelectorAll('.br-action').forEach(function (b) {
      b.addEventListener('click', function () {
        // MakerRun library card opens the sync modal; the rest switch tabs.
        if (b.getAttribute('data-library') && window.BedReadyLibrary && typeof window.BedReadyLibrary.open === 'function') {
          window.BedReadyLibrary.open();
          return;
        }
        if (b.getAttribute('data-filaments') && window.BedReadyFilaments && typeof window.BedReadyFilaments.open === 'function') {
          window.BedReadyFilaments.open();
          return;
        }
        if (b.getAttribute('data-drylog') && window.BedReadyDryLog && typeof window.BedReadyDryLog.open === 'function') {
          window.BedReadyDryLog.open();
          return;
        }
        var go = b.getAttribute('data-go');
        if (go && window.KhaytShell && typeof window.KhaytShell.switchTab === 'function') {
          window.KhaytShell.switchTab(go);
        }
      });
    });
  }

  // Only self-heal AFTER boot has rendered the dashboard at least once. boot's
  // initialRender() calls renderDashboard() after the store loads + applyMode()
  // runs; flipping this flag there keeps us from painting the home before the app
  // is ready (which would let readiness checks pass on a half-booted app).
  var booted = false;

  function brRenderHome() {
    booted = true;
    var el = document.getElementById('dashboardContent');
    if (el) fill(el);
  }

  // ISO title-block strip in the topbar (Cyanotype Draft signature): reframes the page
  // subtitle as a mono, bordered field row (REV · UNITS · DATE) so every view reads like a
  // drawing sheet. Invoked from shell.js' syncTopbarTitle after it sets title/subtitle.
  function brTitleBlock() {
    var sub = document.getElementById('topbarPageSubtitle');
    if (!sub) return;
    var vEl = document.getElementById('appVersion');
    var ver = (vEl && vEl.textContent || '').trim();
    // '—' rather than 'β' when the version has not resolved yet: on a 1.0 build a stray
    // beta mark in the title block would be the one wrong thing on an otherwise stable screen.
    var rev = ver ? ver.replace(/\s*\(dev\)\s*/i, '').replace(/-beta\./i, '·β').replace(/-/g, '·') : '—';
    var mon = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    var d = new Date();
    var date = ('0' + d.getDate()).slice(-2) + ' ' + mon[d.getMonth()] + ' ' + d.getFullYear();
    var esc = function (s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
    var cell = function (l, v) { return '<span class="br-tb-cell"><span class="br-tb-l">' + l + '</span><span class="br-tb-v">' + v + '</span></span>'; };
    sub.innerHTML = '<span class="br-tb">' + cell('REV', esc(rev)) + cell('UNITS', 'mm · g') + cell('DATE', date) + '</span>';
  }
  window.brSyncTitleBlock = brTitleBlock;

  // Swap the shared dashboard renderer for the Bed Ready home (covers
  // initialRender + every tab switch).
  window.renderDashboard = brRenderHome;

  // Self-heal the landing render, which the studio shell clobbers during boot.
  function ensureHome() {
    if (!booted) return;
    var sec = document.getElementById('dashboard-tab');
    var el = document.getElementById('dashboardContent');
    if (sec && sec.classList.contains('active') && el && el.innerHTML.trim().length === 0) {
      fill(el);
    }
  }

  // Re-apply translations once the app has booted, so the copy overrides above
  // land on nav / placeholders / labels that were painted before this ran.
  function reapplyI18n() {
    try { if (typeof i18n !== 'undefined' && typeof i18n.applyToDom === 'function') i18n.applyToDom(); } catch (e) {}
  }

  function startHealing() {
    ensureHome();
    reapplyI18n();
    try { brTitleBlock(); } catch (e) {}
    var sec = document.getElementById('dashboard-tab');
    if (sec && typeof MutationObserver === 'function') {
      // Observe for the WHOLE session and never time out. Boot is async (store load), so the
      // studio shell's re-mount of #dashboardContent — which empties it — can land at an
      // unpredictable time, sometimes seconds after initialRender's first paint. Any fixed
      // window (the old 4s, or a "stable for 1s" heuristic) can expire before that clobber and
      // leave the home permanently blank on a slow/first launch. A persistent observer is cheap
      // and self-limiting: ensureHome() only refills when the dashboard tab is ACTIVE and EMPTY,
      // so it heals the clobber whenever it happens and no-ops during normal use (tab switches
      // call renderDashboard(), leaving it non-empty).
      var obs = new MutationObserver(function () { ensureHome(); });
      obs.observe(sec, { childList: true, subtree: true });
    }
    // Short startup poll: covers any out-of-subtree swap the observer wouldn't see, and re-applies
    // i18n for the first ~1s so the copy overrides land on nav/placeholders painted during boot.
    var tries = 0;
    var iv = setInterval(function () { ensureHome(); if (tries < 8) reapplyI18n(); if (++tries >= 40) clearInterval(iv); }, 120);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startHealing);
  } else {
    startHealing();
  }
})();
