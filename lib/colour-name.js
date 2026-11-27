(function (global) {
  'use strict';
  /*
   * ── A COLOUR'S PLAIN NAME, NOT ITS CODE ───────────────────────────────────
   *
   * Turki, Nov 27 2026: "dont want the color code, the actual color showing,
   * and color name if known". So a spool, a tag or a head shows its swatch and
   * a word a person uses ("Black", "Light grey"), in the shop's language, and
   * never "#080A0D".
   *
   * The name is, in order:
   *   1. the spool's OWN name when it has one: `known` (the catalogue's
   *      `colourVariant`, "Galaxy Black", or a tag's `colorName`): the maker
   *      named it, and that beats any guess;
   *   2. the nearest of a SMALL palette of everyday names, by perceptual
   *      distance (CIEDE2000, lib/color-mix.js: the same maths the colour
   *      planner and the spool matcher use), when it is close enough;
   *   3. nothing: the caller shows the swatch alone. A colour between two
   *      names gets no name rather than a wrong one.
   *
   * Pure and JavaScriptCore-safe.
   */

  function lib(name, file) {
    if (global && global[name]) return global[name];
    if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
    return null;
  }

  /*
   * The palette: a reference colour for each everyday name a shop says about
   * filament. Greys come in three, because black, grey and white PLA are most
   * of a shelf and "grey" alone would cover too much.
   */
  const PALETTE = [
    ['black', '#0A0A0A'], ['dark-grey', '#4A4A4A'], ['grey', '#8C8C8C'], ['light-grey', '#C8C8C8'],
    ['white', '#F7F7F5'], ['silver', '#B4B8BC'], ['red', '#D0202A'], ['dark-red', '#7A1420'],
    ['orange', '#F07A1A'], ['yellow', '#F5D21A'], ['gold', '#C9A227'], ['green', '#2E9E44'],
    ['dark-green', '#1E5631'], ['light-green', '#8FD16A'], ['teal', '#1A8C8C'], ['blue', '#1F5FD1'],
    ['light-blue', '#7EC4F0'], ['navy', '#1B2A55'], ['purple', '#7A3FB0'], ['pink', '#F08CB4'],
    ['magenta', '#C8218C'], ['brown', '#6B4426'], ['beige', '#E2CFA8'], ['skin', '#E8B894'],
    ['olive', '#6B7A1E'], ['cyan', '#1FC7D4'], ['mint', '#9FE3C3'], ['lavender', '#B9A3E3'],
    ['coral', '#F2735A'], ['cream', '#F3E9C9'],
  ];

  /** How far a colour may be from a name's reference and still take its name (CIEDE2000). */
  const MAX_DE = 18;

  const NAMES = {
    en: { black: 'Black', 'dark-grey': 'Dark grey', grey: 'Grey', 'light-grey': 'Light grey', white: 'White', silver: 'Silver', red: 'Red', 'dark-red': 'Dark red', orange: 'Orange', yellow: 'Yellow', gold: 'Gold', green: 'Green', 'dark-green': 'Dark green', 'light-green': 'Light green', teal: 'Teal', blue: 'Blue', 'light-blue': 'Light blue', navy: 'Navy', purple: 'Purple', pink: 'Pink', magenta: 'Magenta', brown: 'Brown', beige: 'Beige', skin: 'Skin tone', olive: 'Olive', cyan: 'Cyan', mint: 'Mint', lavender: 'Lavender', coral: 'Coral', cream: 'Cream' },
    ar: { black: 'أسود', 'dark-grey': 'رمادي غامق', grey: 'رمادي', 'light-grey': 'رمادي فاتح', white: 'أبيض', silver: 'فضي', red: 'أحمر', 'dark-red': 'أحمر غامق', orange: 'برتقالي', yellow: 'أصفر', gold: 'ذهبي', green: 'أخضر', 'dark-green': 'أخضر غامق', 'light-green': 'أخضر فاتح', teal: 'أزرق مخضر', blue: 'أزرق', 'light-blue': 'أزرق فاتح', navy: 'كحلي', purple: 'بنفسجي', pink: 'وردي', magenta: 'أرجواني', brown: 'بني', beige: 'بيج', skin: 'لون البشرة', olive: 'زيتوني', cyan: 'سماوي', mint: 'نعناعي', lavender: 'خزامي', coral: 'مرجاني', cream: 'كريمي' },
    de: { black: 'Schwarz', 'dark-grey': 'Dunkelgrau', grey: 'Grau', 'light-grey': 'Hellgrau', white: 'Weiß', silver: 'Silber', red: 'Rot', 'dark-red': 'Dunkelrot', orange: 'Orange', yellow: 'Gelb', gold: 'Gold', green: 'Grün', 'dark-green': 'Dunkelgrün', 'light-green': 'Hellgrün', teal: 'Petrol', blue: 'Blau', 'light-blue': 'Hellblau', navy: 'Marineblau', purple: 'Lila', pink: 'Rosa', magenta: 'Magenta', brown: 'Braun', beige: 'Beige', skin: 'Hautton', olive: 'Oliv', cyan: 'Cyan', mint: 'Mint', lavender: 'Lavendel', coral: 'Koralle', cream: 'Creme' },
    fr: { black: 'Noir', 'dark-grey': 'Gris foncé', grey: 'Gris', 'light-grey': 'Gris clair', white: 'Blanc', silver: 'Argent', red: 'Rouge', 'dark-red': 'Rouge foncé', orange: 'Orange', yellow: 'Jaune', gold: 'Or', green: 'Vert', 'dark-green': 'Vert foncé', 'light-green': 'Vert clair', teal: 'Bleu canard', blue: 'Bleu', 'light-blue': 'Bleu clair', navy: 'Bleu marine', purple: 'Violet', pink: 'Rose', magenta: 'Magenta', brown: 'Marron', beige: 'Beige', skin: 'Couleur chair', olive: 'Olive', cyan: 'Cyan', mint: 'Menthe', lavender: 'Lavande', coral: 'Corail', cream: 'Crème' },
    es: { black: 'Negro', 'dark-grey': 'Gris oscuro', grey: 'Gris', 'light-grey': 'Gris claro', white: 'Blanco', silver: 'Plata', red: 'Rojo', 'dark-red': 'Rojo oscuro', orange: 'Naranja', yellow: 'Amarillo', gold: 'Dorado', green: 'Verde', 'dark-green': 'Verde oscuro', 'light-green': 'Verde claro', teal: 'Verde azulado', blue: 'Azul', 'light-blue': 'Azul claro', navy: 'Azul marino', purple: 'Morado', pink: 'Rosa', magenta: 'Magenta', brown: 'Marrón', beige: 'Beige', skin: 'Tono piel', olive: 'Oliva', cyan: 'Cian', mint: 'Menta', lavender: 'Lavanda', coral: 'Coral', cream: 'Crema' },
    'pt-BR': { black: 'Preto', 'dark-grey': 'Cinza-escuro', grey: 'Cinza', 'light-grey': 'Cinza-claro', white: 'Branco', silver: 'Prata', red: 'Vermelho', 'dark-red': 'Vermelho-escuro', orange: 'Laranja', yellow: 'Amarelo', gold: 'Dourado', green: 'Verde', 'dark-green': 'Verde-escuro', 'light-green': 'Verde-claro', teal: 'Azul-petróleo', blue: 'Azul', 'light-blue': 'Azul-claro', navy: 'Azul-marinho', purple: 'Roxo', pink: 'Rosa', magenta: 'Magenta', brown: 'Marrom', beige: 'Bege', skin: 'Tom de pele', olive: 'Oliva', cyan: 'Ciano', mint: 'Menta', lavender: 'Lavanda', coral: 'Coral', cream: 'Creme' },
    ja: { black: '黒', 'dark-grey': 'ダークグレー', grey: 'グレー', 'light-grey': 'ライトグレー', white: '白', silver: 'シルバー', red: '赤', 'dark-red': '暗い赤', orange: 'オレンジ', yellow: '黄色', gold: 'ゴールド', green: '緑', 'dark-green': '深緑', 'light-green': '黄緑', teal: 'ティール', blue: '青', 'light-blue': '水色', navy: '紺', purple: '紫', pink: 'ピンク', magenta: 'マゼンタ', brown: '茶色', beige: 'ベージュ', skin: '肌色', olive: 'オリーブ', cyan: 'シアン', mint: 'ミント', lavender: 'ラベンダー', coral: 'コーラル', cream: 'クリーム' },
    zh: { black: '黑色', 'dark-grey': '深灰色', grey: '灰色', 'light-grey': '浅灰色', white: '白色', silver: '银色', red: '红色', 'dark-red': '深红色', orange: '橙色', yellow: '黄色', gold: '金色', green: '绿色', 'dark-green': '深绿色', 'light-green': '浅绿色', teal: '青色', blue: '蓝色', 'light-blue': '浅蓝色', navy: '海军蓝', purple: '紫色', pink: '粉色', magenta: '品红色', brown: '棕色', beige: '米色', skin: '肤色', olive: '橄榄色', cyan: '青蓝色', mint: '薄荷绿', lavender: '薰衣草紫', coral: '珊瑚色', cream: '奶油色' },
    tr: { black: 'Siyah', 'dark-grey': 'Koyu gri', grey: 'Gri', 'light-grey': 'Açık gri', white: 'Beyaz', silver: 'Gümüş', red: 'Kırmızı', 'dark-red': 'Koyu kırmızı', orange: 'Turuncu', yellow: 'Sarı', gold: 'Altın', green: 'Yeşil', 'dark-green': 'Koyu yeşil', 'light-green': 'Açık yeşil', teal: 'Petrol mavisi', blue: 'Mavi', 'light-blue': 'Açık mavi', navy: 'Lacivert', purple: 'Mor', pink: 'Pembe', magenta: 'Macenta', brown: 'Kahverengi', beige: 'Bej', skin: 'Ten rengi', olive: 'Zeytin yeşili', cyan: 'Camgöbeği', mint: 'Nane yeşili', lavender: 'Lavanta', coral: 'Mercan', cream: 'Krem' },
  };
  const LANGS = Object.keys(NAMES);

  /** The language's table, by its tag ("pt-BR", "zh-Hans" → zh, "ar-SA" → ar); English when unknown. */
  function table(lang) {
    const l = String(lang || 'en');
    if (NAMES[l]) return NAMES[l];
    const base = l.split(/[-_]/)[0];
    return NAMES[base] || NAMES.en;
  }

  /**
   * The nearest everyday colour for a hex, as { key, deltaE }; null when the
   * hex is not a colour or nothing is within MAX_DE.
   */
  function nearestKey(hex) {
    const CM = lib('KhaytColor', './color-mix.js');
    if (!CM || typeof CM.hexToLab !== 'function' || typeof CM.ciede2000 !== 'function') return null;
    const lab = CM.hexToLab(String(hex || ''));
    if (!lab) return null;
    let best = null;
    for (const [key, ref] of PALETTE) {
      const d = CM.ciede2000(lab, CM.hexToLab(ref));
      if (best === null || d < best.deltaE) best = { key, deltaE: Math.round(d * 10) / 10 };
    }
    return best && best.deltaE <= MAX_DE ? best : null;
  }

  /**
   * The words to show for a colour: the spool's own name (`opts.known`) when it
   * has one, else the nearest everyday name in `lang`, else null (show the
   * swatch alone). Never a hex.
   */
  function colourName(hex, lang, opts) {
    const known = opts && typeof opts.known === 'string' ? opts.known.trim() : '';
    if (known && !/^#?[0-9a-f]{6}$/i.test(known)) return known;
    const n = nearestKey(hex);
    return n ? table(lang)[n.key] : null;
  }

  const api = { colourName, nearestKey, PALETTE, MAX_DE, LANGS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytColourName = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
