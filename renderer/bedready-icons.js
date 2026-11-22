'use strict';
/*
 * Bed Ready — bespoke line-symbol set (Cyanotype Draft redesign, Phase 2).
 *
 * Replaces emoji markers (a top "AI-generic" tell) with a coherent drafting-style icon family:
 * a 24-unit grid, 1.6 stroke, square caps + miter joins (technical, un-rounded), drawn in
 * currentColor so each icon inherits its context's ink/accent. Bed Ready-only; consumed by the
 * renderers via window.BedReadyIcons.get(name[, size]).
 */
(function () {
  // Path bodies on a 0..24 viewBox. Kept geometric so the set reads as one engineered family.
  var P = {
    // retarget — two swap arrows
    convert: '<path d="M4 8H17"/><path d="M14 5L17 8L14 11"/><path d="M20 16H7"/><path d="M10 13L7 16L10 19"/>',
    // colour mixing — two overlapping loops
    colour: '<circle cx="9.5" cy="10" r="5"/><circle cx="15" cy="14" r="5"/>',
    // job board — a short stack of rows
    queue: '<path d="M5 7H19"/><path d="M5 12H19"/><path d="M5 17H13"/>',
    // filament reel (side view) — two flanges + wound band
    spool: '<path d="M6 5V19"/><path d="M18 5V19"/><path d="M6 8H18"/><path d="M6 16H18"/>',
    // 3D model — isometric cube
    cube: '<path d="M12 3L20 7.5L12 12L4 7.5Z"/><path d="M4 7.5V16.5L12 21V12"/><path d="M20 7.5V16.5L12 21"/>',
    // cost per print — calculator
    calc: '<rect x="5" y="3" width="14" height="18"/><path d="M8 7H16"/><path d="M8 12H10"/><path d="M14 12H16"/><path d="M8 16H10"/><path d="M14 16H16"/>',
    // synced library — cloud
    cloud: '<path d="M8 18H16.5A3.5 3.5 0 0 0 17 11.1A5 5 0 0 0 7.3 10.2A4 4 0 0 0 8 18Z"/>',
    // slicer profile — extruder nozzle
    nozzle: '<path d="M8 4H16V10L12 20L8 10Z"/><path d="M8 10H16"/>',
    // filament care — drying droplet
    droplet: '<path d="M12 3C12 3 6 10.5 6 15A6 6 0 0 0 18 15C18 10.5 12 3 12 3Z"/>',
    // print bed / plate — isometric platform with a grid line
    plate: '<path d="M3 9L12 4L21 9L12 14Z"/><path d="M6 10.7V15L12 18.5L18 15V10.7"/>',
    // calibrate — target crosshair
    target: '<circle cx="12" cy="12" r="7.5"/><circle cx="12" cy="12" r="3"/><path d="M12 1V5"/><path d="M12 19V23"/><path d="M1 12H5"/><path d="M19 12H23"/>',
    // open in slicer — printer
    printer: '<path d="M7 4H17V9H7Z"/><path d="M4 9H20V16H16"/><path d="M4 16H8"/><path d="M8 14H16V20H8Z"/>',
    // delete — waste bin
    trash: '<path d="M5 7H19"/><path d="M9 7V4H15V7"/><path d="M7 7L8 20H16L17 7"/><path d="M10 11V16"/><path d="M14 11V16"/>',
    // folder tag — drafting folder
    folder: '<path d="M4 6H10L12 8H20V18H4Z"/>',
    // gcode / document — sheet with folded corner
    doc: '<path d="M7 3H14L18 7V21H7Z"/><path d="M14 3V7H18"/><path d="M10 12H15"/><path d="M10 16H15"/>',
    // print time — clock
    clock: '<circle cx="12" cy="12" r="8"/><path d="M12 7V12L15 15"/>',
    // warning — triangle with bang
    alert: '<path d="M12 3L22 20H2Z"/><path d="M12 9V14"/><path d="M12 17H12.01"/>',
    // ok / in-spec — check
    check: '<path d="M4 12L10 18L20 6"/>',
    // dry / temperature — thermometer
    thermo: '<path d="M10 4A2 2 0 0 1 14 4V13A4 4 0 1 1 10 13Z"/><path d="M12 9V15"/>',
    // test prints — flask
    flask: '<path d="M9 3H15"/><path d="M10.5 3V9L5 19H19L13.5 9V3"/><path d="M8 15H16"/>',
    // spool history — clipboard
    clipboard: '<rect x="6" y="4" width="12" height="17"/><rect x="9" y="2.5" width="6" height="3"/><path d="M9 10H15"/><path d="M9 14H15"/>',
    // label / QR — tag
    tag: '<path d="M4 4H11L20 13L13 20L4 11Z"/><circle cx="8" cy="8" r="1.2"/>',
    // price history — trend line
    trend: '<path d="M4 16L10 10L13 13L20 6"/><path d="M15 6H20V11"/>',
    // supplier — works / factory
    factory: '<path d="M3 21V9L9 13V9L15 13V9L21 13V21Z"/><path d="M7 21V17"/><path d="M12 21V17"/><path d="M17 21V17"/>',
    // scan label — camera
    camera: '<path d="M3 8H7L9 5H15L17 8H21V19H3Z"/><circle cx="12" cy="13" r="3.5"/>',
    // hold — pause
    pause: '<path d="M8 5V19"/><path d="M16 5V19"/>',
    // resume — play
    play: '<path d="M7 4L19 12L7 20Z"/>',
    // fail / reject — cross
    cross: '<path d="M6 6L18 18"/><path d="M18 6L6 18"/>',
    // attachment — clip
    clip: '<path d="M20 11L11.5 19.5A5 5 0 0 1 4.5 12.5L13 4A3.3 3.3 0 0 1 17.7 8.7L9.5 17A1.7 1.7 0 0 1 7 14.5L15 6.5"/>',
    // cure — sun
    sun: '<circle cx="12" cy="12" r="4.5"/><path d="M12 2V5"/><path d="M12 19V22"/><path d="M2 12H5"/><path d="M19 12H22"/><path d="M4.5 4.5L6.5 6.5"/><path d="M17.5 17.5L19.5 19.5"/><path d="M4.5 19.5L6.5 17.5"/><path d="M17.5 6.5L19.5 4.5"/>',
    // ETA / finish — flag
    flag: '<path d="M6 21V4"/><path d="M6 4H18L15 8L18 12H6"/>',
    // maintenance — wrench
    wrench: '<path d="M16.5 3.5A4 4 0 0 0 12.2 8.8L4 17L7 20L15.2 11.8A4 4 0 0 0 20.5 7.5L17.5 10.5L13.5 6.5Z"/>',
    // detect / search — magnifier
    search: '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15L20 20"/>',
    // add — plus
    plus: '<path d="M12 5V19"/><path d="M5 12H19"/>',
    // filament painting — framed image with a horizon
    image: '<rect x="3" y="5" width="18" height="14"/><path d="M3 15L9 10L13 13L17 10L21 13"/><circle cx="8" cy="9" r="1.4"/>',
    // fallback
    dot: '<circle cx="12" cy="12" r="3"/>',
  };

  function get(name, size) {
    var body = P[name] || P.dot;
    var s = size || 20;
    return '<svg viewBox="0 0 24 24" width="' + s + '" height="' + s + '" fill="none" stroke="currentColor" ' +
      'stroke-width="1.6" stroke-linecap="square" stroke-linejoin="miter" aria-hidden="true" focusable="false">' + body + '</svg>';
  }

  window.BedReadyIcons = { get: get, has: function (n) { return Object.prototype.hasOwnProperty.call(P, n); } };
})();
