/* Khayt Studio — vanilla SVG chart primitives (no deps) */
(function () {
  function donutSvg(segments, size, stroke) {
    size = size || 132;
    stroke = stroke || 18;
    const r = (size - stroke) / 2;
    const c = 2 * Math.PI * r;
    let acc = 0;
    const total = segments.reduce((s, x) => s + (x.pct || 0), 0) || 100;
    const circles = segments.map((s, i) => {
      const len = ((s.pct || 0) / total) * c;
      const el =
        `<circle cx="${size / 2}" cy="${size / 2}" r="${r}" fill="none" stroke="${s.color}" ` +
        `stroke-width="${stroke}" stroke-dasharray="${len} ${c - len}" stroke-dashoffset="${-acc}" />`;
      acc += len;
      return el;
    }).join('');
    return (
      `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" class="khayt-donut-svg" aria-hidden="true">` +
      `<g transform="rotate(-90 ${size / 2} ${size / 2})">${circles}</g></svg>`
    );
  }

  window.KhaytCharts = { donutSvg };
})();
