/* ============================================================
   Khayt line icons — one shared, quiet vocabulary
   ============================================================

   The redesign's rule is quiet by default, colour only for conditions. A
   toolbar of 📅📆📋🤖🖥 breaks it twice: the glyphs shout, and they render in
   whatever colour and metrics the OS emoji font decides, which is neither the
   app's ink nor consistent across Windows/macOS/Linux.

   These are single-stroke 24-grid paths drawn in currentColor, so they inherit
   the button's text colour and sit on the baseline like text. Same shape the
   workbench theme already used inline (ICON/svg there); promoted here so the
   shared chrome and every theme can draw from one set instead of each keeping
   its own.

   Add a glyph by name; never inline an emoji in markup that this could cover.
   ============================================================ */
(function (global) {

  const PATHS = {
    // calendar / schedule
    calendar: '<rect x="3" y="4" width="18" height="17" rx="2"/><path d="M3 9h18M8 2v4M16 2v4"/>',
    // timeline / schedule-by-time
    schedule: '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l3 2M9 2h6"/>',
    // clipboard / batch planner / report
    clipboard: '<rect x="5" y="4" width="14" height="18" rx="2"/><path d="M9 4V3a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v1M9 12h6M9 16h4"/>',
    // wand / auto-suggest (was 🤖 / 🪄)
    wand: '<path d="M15 4V2M15 10V8M11 6H9M21 6h-2M18.4 3.6l-1.4 1.4M13 8l-8 8-2-2 8-8zM19.4 4.6L18 6"/>',
    // monitor / kiosk
    monitor: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/>',
    // printer
    printer: '<path d="M6 9V3h12v6M6 18H5a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2h-1M6 14h12v7H6z"/>',
    // spool / filament
    spool: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><path d="M12 3v6M12 15v6"/>',
    // play / start shift
    play: '<path d="M6 3l14 9-14 9V3z"/>',
    // pause / hold production
    pause: '<path d="M9 4.5v15M15 4.5v15"/>',

    /* ── Added for the print library, which was still on emoji ──────────────
     * This file has said since it was written: "never inline an emoji in
     * markup that this could cover." The print-file cards were covered by
     * nothing — `_bi()` only reached for a real icon in the Bed Ready flavour,
     * so Khayt drew 🖨 🛠 🔎 🧊 🎨 🔄 🗑 in a row, at whatever colour and
     * metrics the OS emoji font chose. These are the glyphs that row needed. */
    // tool / the settings that worked
    nozzle: '<path d="M7 3h10l-1.4 8H8.4L7 3z"/><path d="M10 11l2 4 2-4"/>',
    // magnifier / identify this model
    search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4.3-4.3"/>',
    // cube / view in 3D
    cube: '<path d="M12 2.5l8.5 4.8v9.4L12 21.5 3.5 16.7V7.3L12 2.5z"/><path d="M12 21.5V12M3.5 7.3L12 12l8.5-4.7"/>',
    // palette / plan colours
    palette: '<path d="M12 3a9 9 0 1 0 0 18c1 0 1.6-.6 1.6-1.4 0-.5-.3-.9-.6-1.2-.3-.4-.5-.7-.5-1.2 0-.8.7-1.4 1.5-1.4H16a5 5 0 0 0 5-5c0-4.4-4-7.8-9-7.8z"/><circle cx="7.5" cy="11.5" r=".9"/><circle cx="10.5" cy="7.5" r=".9"/><circle cx="15" cy="8.5" r=".9"/>',
    // two arrows round / convert to another printer
    convert: '<path d="M20.5 11A8.5 8.5 0 0 0 6.4 5.6L3.5 8.2"/><path d="M3.5 13A8.5 8.5 0 0 0 17.6 18.4l2.9-2.6"/><path d="M3.5 3.4v4.8h4.8M20.5 20.6v-4.8h-4.8"/>',
    // bin / delete
    trash: '<path d="M4 7h16M9.5 7V5.2a1.2 1.2 0 0 1 1.2-1.2h2.6a1.2 1.2 0 0 1 1.2 1.2V7M6.5 7l.9 12.4a1.4 1.4 0 0 0 1.4 1.3h6.4a1.4 1.4 0 0 0 1.4-1.3L17.5 7M10.3 11v6M13.7 11v6"/>',
    // pencil / edit
    pencil: '<path d="M4 20h4l10.5-10.5a2.1 2.1 0 0 0-3-3L5 17v3z"/><path d="M14.5 6.5l3 3"/>',
    // tick / it printed
    check: '<path d="M20 6.5L9.3 17.2 4 12"/>',
    // cross / it failed
    cross: '<path d="M17.5 6.5l-11 11M6.5 6.5l11 11"/>',
    /* Three dots, FILLED: outlined circles at 15px read as three rings rather
     * than as dots. The wrapper sets fill:none for the line glyphs, so these
     * say otherwise for themselves. */
    more: '<circle cx="5.2" cy="12" r="1.5" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none"/><circle cx="18.8" cy="12" r="1.5" fill="currentColor" stroke="none"/>',
    // plus / add a file
    plus: '<path d="M12 5.2v13.6M5.2 12h13.6"/>',
    // up-down arrows / sort
    sort: '<path d="M7 20V4.5M7 4.5L4.2 7.6M7 4.5l2.8 3.1M17 4v15.5M17 19.5l-2.8-3.1M17 19.5l2.8-3.1"/>',
    // columns / board view
    board: '<rect x="3.5" y="4.5" width="5" height="15" rx="1.2"/><rect x="9.5" y="4.5" width="5" height="10" rx="1.2"/><rect x="15.5" y="4.5" width="5" height="13" rx="1.2"/>',
    // rows / list view
    list: '<path d="M4 7h16M4 12h16M4 17h10"/>',
    // target / calibrate
    target: '<circle cx="12" cy="12" r="7.5"/><circle cx="12" cy="12" r="2.8"/><path d="M12 2.2v2.6M12 19.2v2.6M2.2 12h2.6M19.2 12h2.6"/>',
    // folder
    folder: '<path d="M3 7.5a2 2 0 0 1 2-2h3.8l2 2H19a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-9.5z"/>',
    // cloud / sync
    cloud: '<path d="M7.2 18.5a4.2 4.2 0 0 1 .3-8.4 6 6 0 0 1 11.3 2 3.6 3.6 0 0 1-.8 6.4H7.2z"/>',

    /* ── For the toolbars and rows that followed the print library ────────── */
    // sheet of paper / a form, a document
    doc: '<path d="M6 2.8h7.5L19 8.3v12.9H6z"/><path d="M13.5 2.8v5.5H19M9 13h6M9 16.5h4"/>',
    // arrow into a tray / export, download
    download: '<path d="M12 3.5v11M12 14.5l-4-4M12 14.5l4-4M4.5 17.5v1.6a1.4 1.4 0 0 0 1.4 1.4h12.2a1.4 1.4 0 0 0 1.4-1.4v-1.6"/>',
    // arrow out of a tray / import, upload
    upload: '<path d="M12 15V4M12 4L8 8M12 4l4 4M4.5 17.5v1.6a1.4 1.4 0 0 0 1.4 1.4h12.2a1.4 1.4 0 0 0 1.4-1.4v-1.6"/>',
    // megaphone / campaign
    megaphone: '<path d="M4 10.5v3a1.5 1.5 0 0 0 1.5 1.5H8l6.5 4V5L8 9H5.5A1.5 1.5 0 0 0 4 10.5z"/><path d="M18 9.2a4.5 4.5 0 0 1 0 5.6M7.5 15v4.5h2.2"/>',
    // arrows in a loop / a subscription, something that repeats
    repeat: '<path d="M4.5 9.5A5 5 0 0 1 9.4 5.5h9.3"/><path d="M15.8 2.6l2.9 2.9-2.9 2.9"/><path d="M19.5 14.5a5 5 0 0 1-4.9 4H5.3"/><path d="M8.2 21.4l-2.9-2.9 2.9-2.9"/>',
    // receipt / an activity log, a record of what happened
    receipt: '<path d="M5.5 2.8h13v18.4l-2.2-1.5-2.2 1.5-2.1-1.5-2.2 1.5-2.2-1.5-2.1 1.5z"/><path d="M9 8h6M9 12h6"/>',
    // speech bubble / a reminder sent to someone
    message: '<path d="M20.5 12.2c0 3.8-3.8 6.9-8.5 6.9a10 10 0 0 1-2.6-.3L4 21l1.4-3.6a6.4 6.4 0 0 1-1.9-4.4c0-3.8 3.8-6.9 8.5-6.9s8.5 3.1 8.5 6.9z"/>',
    // chain / a link to share
    link: '<path d="M10 13.8a4 4 0 0 0 5.7 0l2.6-2.6a4 4 0 0 0-5.7-5.7l-1.5 1.5"/><path d="M14 10.2a4 4 0 0 0-5.7 0l-2.6 2.6a4 4 0 0 0 5.7 5.7l1.5-1.5"/>',
    // arrow out of a box / share, send onward
    share: '<path d="M12 3.5v11"/><path d="M8.4 7.1L12 3.5l3.6 3.6"/><path d="M4.8 12.5v6.6a1.4 1.4 0 0 0 1.4 1.4h11.6a1.4 1.4 0 0 0 1.4-1.4v-6.6"/>',
    // arrow rightwards / move this on to the next thing
    forward: '<path d="M4 12h15M13.5 6.5L20 12l-6.5 5.5"/>',
  };

  /**
   * @param {string} name  one of PATHS
   * @param {number} [size=15]
   * @returns {string} inline SVG, or '' for an unknown name (never a broken tag)
   */
  function icon(name, size) {
    const d = PATHS[name];
    if (!d) return '';
    const s = (+size > 0) ? +size : 15;
    return `<svg class="khayt-ico" viewBox="0 0 24 24" width="${s}" height="${s}" fill="none"`
      + ` stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"`
      + ` aria-hidden="true" focusable="false">${d}</svg>`;
  }

  /**
   * Fill every [data-khayt-icon] element under `root` with its glyph. Lets
   * static markup (the queue toolbar) declare an icon by name and stay one
   * source of truth with the dynamic surfaces. Idempotent: a hydrated element
   * carries data-icon-done so a re-render never double-fills it.
   * @param {ParentNode} [root=document]
   */
  function hydrateIcons(root) {
    const scope = root || (typeof document !== 'undefined' ? document : null);
    if (!scope || !scope.querySelectorAll) return;
    scope.querySelectorAll('[data-khayt-icon]:not([data-icon-done])').forEach((el) => {
      const svg = icon(el.getAttribute('data-khayt-icon'), +el.getAttribute('data-icon-size') || 15);
      if (!svg) return;
      el.insertAdjacentHTML('afterbegin', svg);
      el.setAttribute('data-icon-done', '1');
    });
  }

  const api = { icon, hydrateIcons, PATHS };
  Object.assign(global, { khaytIcon: icon });
  global.KhaytIcons = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;

})(typeof globalThis !== 'undefined' ? globalThis : window);
