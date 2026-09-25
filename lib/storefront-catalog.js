'use strict';

/**
 * The storefront catalogue — the exact payload a shop PUTs to
 * /v1/shops/{id}/catalog — built in one place for every host.
 *
 * It lived inside renderer/settings.js's Storefront dialog, which meant the
 * native Mac app could not publish at all: a shop on the Mac had products in
 * its book and one in its store, and the only way to fix it was a second
 * builder in Swift, which would drift from this one the first time either
 * changed. So the payload is assembled here, pure, and each host supplies only
 * what it alone can: the shop's name as it displays it, the interface
 * language, and the resized hero pictures (the renderer through a canvas, the
 * Mac through ImageIO, both at KhaytProductImages.HERO_MAX_DIM / HERO_QUALITY).
 *
 * What is NOT here: reading the Storefront dialog's form into
 * `settings.storefront` (captureConfig, renderer-only), and sending the
 * payload (the host's cloud client).
 *
 * Every rule below was written in the renderer first; the comments came with
 * it, because each one is a defect that shipped once.
 */
(function (global) {
  const need = (name, file) => {
    const g = global[name];
    if (g) return g;
    if (typeof require === 'function') return require(file);
    throw new Error(`storefront-catalog: ${name} is not loaded`);
  };

  /** The most listings one catalogue carries. */
  const MAX_PRODUCTS = 60;

  /** "Color: Black, White; Size: S, M" → [{name, values}]; ≤5 groups, ≤12 values. */
  function parseOptionGroups(raw) {
    return String(raw || '').split(';').map((seg) => {
      const ci = seg.indexOf(':');
      if (ci < 0) return null;
      const name = seg.slice(0, ci).trim().slice(0, 40);
      const values = seg.slice(ci + 1).split(',').map((v) => v.trim().slice(0, 40)).filter(Boolean).slice(0, 12);
      return (name && values.length) ? { name, values } : null;
    }).filter(Boolean).slice(0, 5);
  }

  /**
   * The products a catalogue lists: the first MAX_PRODUCTS that have a name the
   * shop can read — `nameEn`, or the name in the interface language through the
   * content-language model (renderer/app-helpers.js localName).
   */
  function publishable(products, settings, lang) {
    const CL = need('KhaytContentLanguages', './content-languages.js');
    /* `storefrontHidden` first, then the cap: a shop that hides a test piece
     * must not lose its sixtieth real one to it. A field on the PRODUCT, not a
     * map in settings.storefront, because a product syncs record by record
     * and settings do not. */
    return (Array.isArray(products) ? products : [])
      .filter((p) => p && !p.storefrontHidden)
      .slice(0, MAX_PRODUCTS).filter((p) =>
        String(p.nameEn || CL.read(p, 'name', lang || 'en', settings || null) || '').trim());
  }

  /**
   * What a customer would find wrong with each listing, before it is published.
   *
   * The first catalogue published from the Mac put a test description ("how
   * are you"), three listings with no picture and Arabic names that were file
   * names in front of customers, and nothing said so until someone opened the
   * website. These are the questions a shop owner would ask of a listing by
   * eye; each answer is a key the host translates.
   *
   *   no_price        nothing to charge (no catalogue or storefront price)
   *   no_photo        no picture a customer can see
   *   no_description  nothing to read in the shop's first language
   *   no_category     cannot be filed with anything else in the store
   *   second_language the second language is missing or repeats the first
   *   file_name       a name that reads like a file (underscores, "+", an
   *                   extension, or a run of words with no spaces)
   *
   * @returns {{hidden: number, listings: Array<{id, name, issues: string[]}>}}
   *          only listings with at least one issue, in book order
   */
  function review(products, settings, lang) {
    const CL = need('KhaytContentLanguages', './content-languages.js');
    const IMG = need('KhaytProductImages', './product-images.js');
    const all = Array.isArray(products) ? products : [];
    const langs = CL.contentLangs(settings || {});
    const sf = Object.assign({ prices: {}, categories: {} }, (settings && settings.storefront) || {});
    const Org = global.KhaytOrganise || null;
    const filey = (name) => {
      const n = String(name || '').trim();
      if (!n) return false;
      if (/[_+]/.test(n) || /\.(3mf|stl|obj|step|gcode)$/i.test(n)) return true;
      // "AquaticFlexiDragon-U1": several words run together, no spaces.
      return !/\s/.test(n) && /[a-z][A-Z]/.test(n) && n.length > 10;
    };
    const listings = [];
    for (const p of publishable(all, settings, lang)) {
      const issues = [];
      const sfPrice = sf.prices[p.id];
      const price = (sfPrice != null && String(sfPrice).trim() !== '') ? sfPrice
        : (p.price != null ? p.price : p.basePrice);
      if (price == null || String(price).trim() === '') issues.push('no_price');
      const seen = IMG.normalise(p).images.some((img) =>
        typeof img.thumbnail === 'string' && /^data:image\//.test(img.thumbnail));
      if (!seen) issues.push('no_photo');
      if (!CL.read(p, 'description', langs[0], settings).trim()) issues.push('no_description');
      const cat = (sf.categories[p.id] && String(sf.categories[p.id]).trim())
        || (Org ? Org.categoryOf(p) : String(p.category || '').trim());
      if (!cat) issues.push('no_category');
      const first = String(p[CL.fieldKey('name', langs[0])] || '').trim();
      if (langs[1]) {
        const second = String(p[CL.fieldKey('name', langs[1])] || '').trim();
        if (!second || second === first) issues.push('second_language');
      }
      if (langs.some((l) => filey(p[CL.fieldKey('name', l)]))) issues.push('file_name');
      if (issues.length) {
        listings.push({ id: p.id, name: CL.read(p, 'name', langs[0], settings).trim(), issues });
      }
    }
    return { hidden: all.filter((p) => p && p.storefrontHidden).length, listings };
  }

  /** A hero lookup that takes a Map or a plain object, keyed by image path. */
  const heroGetter = (heroes) => {
    if (!heroes) return () => '';
    if (typeof heroes.get === 'function') return (k) => heroes.get(k) || '';
    return (k) => heroes[k] || '';
  };

  /**
   * @param {object} a
   * @param {object[]} a.products       the book's products
   * @param {object}   a.settings       the book's settings
   * @param {object}  [a.storefront]    settings.storefront (defaults to it)
   * @param {string}  [a.shopName]      the shop's name as the host shows it
   * @param {string}  [a.lang]          the interface language
   * @param {boolean} [a.withPhotos]    false publishes no pictures at all
   * @param {Map|object} [a.heroes]     image path → web-sized data URL
   * @returns {object} the catalogue payload
   */
  function build(a) {
    const o = a || {};
    const settings = o.settings || {};
    const sf = Object.assign({ prices: {}, categories: {}, soldOut: {}, options: {}, stockQty: {}, stockCountedAt: {} },
      o.storefront || settings.storefront || {});
    const lang = o.lang || 'en';
    const withPhotos = o.withPhotos !== false;
    // Named as the renderer named them, so the rules pinned against the old
    // builder's source (test/storefront-payload-contract.test.js) still read.
    const KhaytContentLanguages = need('KhaytContentLanguages', './content-languages.js');
    const KhaytProductImages = need('KhaytProductImages', './product-images.js');
    const KhaytProductSpecs = need('KhaytProductSpecs', './product-specs.js');
    const CL = KhaytContentLanguages;
    const Org = global.KhaytOrganise || null;
    const hero = heroGetter(o.heroes);
    const langs = KhaytContentLanguages.contentLangs(settings);

    const payload = {
      shopName: (String(o.shopName || '') || 'Khayt').trim(),
      currency: settings.currency || 'SAR',
      lang,
      /* The languages this catalogue is WRITTEN in, so the storefront page
       * can offer them. It used to be able to show English or Arabic and
       * nothing else — hard-coded, with `lang === 'ar' ? nameAr : name` —
       * so a German-and-French shop published a catalogue its own customers
       * could only read half of. */
      langs: KhaytContentLanguages.contentLangs(settings),
      note: sf.note,
      leadTime: sf.leadTime || '',
      minOrder: sf.minOrder || 0,
      depositPct: sf.depositPct || 0,
      taxRate: sf.taxRate || 0,
      shipping: sf.shipping || [],
      payUrl: /^https?:\/\//i.test(sf.payUrl || '') ? sf.payUrl : '',
      promos: sf.promos || [],
      items: publishable(o.products, settings, lang).map((p) => {
        /* Read through the content-language model rather than the two
         * hard-coded fields: a shop writing Turkish or German published a
         * blank name and no description at all, because the storefront only
         * knew about `nameEn`, `nameAr` and a single unsuffixed
         * `description`. `name`/`nameAr` stay in the payload because the
         * published storefront page reads exactly those. */
        const it = {
          id: p.id,
          name: CL.read(p, 'name', langs[0], settings).trim(),
          nameAr: (p.nameAr || '').trim(),
          desc: CL.read(p, 'description', langs[0], settings).trim(),
        };
        // The second language, where the shop keeps one, so a storefront
        // can show a customer the listing in their own.
        if (langs[1]) {
          const alt = CL.read(p, 'name', langs[1], settings).trim();
          const altDesc = CL.read(p, 'description', langs[1], settings).trim();
          if (alt || altDesc) it.alt = { lang: langs[1], name: alt, desc: altDesc };
        }
        /* The catalogue's own price is the price. A storefront entry is an
         * OVERRIDE, not the only source. `!= null` rather than a truthy test,
         * because 0 is a price: a giveaway priced at nothing is a decision. */
        const sfPrice = sf.prices[p.id];
        const price = (sfPrice != null && String(sfPrice).trim() !== '')
          ? sfPrice
          : (p.price != null ? p.price : p.basePrice);
        if (price != null && String(price).trim() !== '') it.price = String(price);
        /* The same override-not-only-source rule for the category: the
         * storefront entry wins where it is set, the product's own record
         * fills the rest. */
        const sfCat = sf.categories[p.id];
        const cat = (sfCat && String(sfCat).trim()) || (Org ? Org.categoryOf(p) : String(p.category || '').trim());
        if (cat) it.category = cat;
        // The collection this belongs to, so a storefront can show a set together.
        const grp = Org ? Org.groupOf(p) : String(p.group || p.folder || '').trim();
        if (grp) it.group = grp;
        if (sf.soldOut[p.id]) it.soldOut = true;
        /* The batch on the shelf. != null: 0 is a sold-out batch and is
         * published as 0, or the piece reads as made to order. */
        if (sf.stockQty[p.id] != null) {
          it.stockQty = sf.stockQty[p.id];
          if (sf.stockCountedAt[p.id]) it.stockCountedAt = sf.stockCountedAt[p.id];
        }
        /* What the thing is. printHours is MACHINE time only; finishing is
         * published in the lead-time snapshot, so adding it here would count
         * it twice. */
        const spec = KhaytProductSpecs.productSpecs(p);
        if (spec.printHours != null) it.printHours = spec.printHours;
        if (spec.weightGrams != null) it.weightGrams = spec.weightGrams;
        if (spec.material) it.material = spec.material;
        const og = parseOptionGroups(sf.options[p.id]);
        if (og.length) it.options = og;
        /* Photos: more than one, each saying what it is. `photo` is NOT set:
         * the server derives it from photos[0], and sending it put every
         * primary picture on the wire twice. */
        if (withPhotos) {
          const photos = KhaytProductImages.storefrontPhotos(p, {
            hero: (img) => hero(img.path),
          });
          if (photos.length) it.photos = photos;
        }
        return it;
      }).filter((it) => it.name),
    };
    /* Trim the pictures to what the server accepts (8 MB sanitised) rather
     * than let the whole publish fail with 413. Extra photos go before anyone's
     * only photo. */
    KhaytProductImages.fitCatalogPhotos(payload.items);
    return payload;
  }

  const api = { build, publishable, review, parseOptionGroups, MAX_PRODUCTS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStorefrontCatalog = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
