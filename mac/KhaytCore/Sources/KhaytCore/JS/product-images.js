'use strict';
/**
 * A product's pictures — more than one, and each of them says what it IS.
 *
 * The catalog stored exactly two fields: `imagePath` (one file on disk) and
 * `thumbnail` (one data URI for the grid). The picker had no `multiple`, and
 * saving a new picture deleted the old one. So a shop selling a printed part had
 * one slot to hold a render, a photo of the real thing, a scale shot and a
 * detail of the finish — and had to choose.
 *
 * WHY THE LABEL MATTERS MORE THAN THE COUNT. A customer looking at a listing is
 * asking one question the pictures rarely answer: is that a render, or is that
 * what arrives? Guessing wrong is a refund. The print library already draws this
 * distinction for its own files — `thumb` for the slicer's preview and
 * `userPhoto` for a photo of the printed part — so the idea existed in the app
 * and had simply never reached products.
 *
 * ── The shape ───────────────────────────────────────────────────────────────
 *   images: [{ id, path, thumbnail, kind, caption }]
 *
 * `kind` is one of KINDS below. The FIRST image is the primary one: it is what
 * the grid, the storefront and the invoice use, so ordering is a decision the
 * shop makes rather than an accident of upload order.
 *
 * `imagePath` and `thumbnail` are still written, mirroring the primary. Every
 * other part of the app reads them — the storefront catalog, the published
 * portal, label printing — and a migration that renamed the field everywhere at
 * once would be a much larger and much riskier change than this one. They are a
 * VIEW of images[0], kept in step by normalise(), not a second source of truth.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /**
   * What a picture is. Ordered as a shop would shoot them.
   *
   * `print` is the one that earns this whole file: a photograph of the actual
   * printed part. It is deliberately the second entry rather than the first,
   * because a render is usually what exists first and the honest label is worth
   * more than a flattering default.
   */
  const KINDS = [
    { key: 'render', label: 'Render', hint: 'A CAD or slicer render — not a photo of a real part.' },
    { key: 'print', label: 'Actual print', hint: 'A photograph of the printed part itself.' },
    { key: 'detail', label: 'Detail', hint: 'A close-up: finish, texture, a join, a moving part.' },
    { key: 'scale', label: 'Scale', hint: 'The part next to something recognisable, so size reads.' },
    { key: 'packaging', label: 'Packaging', hint: 'How it arrives.' },
  ];

  const KIND_KEYS = KINDS.map((k) => k.key);
  const DEFAULT_KIND = 'render';

  /** A stable-enough id for an image that has none. */
  function imageId(seed, index) {
    return `PIMG-${String(seed || 'x').replace(/[^A-Za-z0-9]/g, '').slice(0, 10)}-${index}`;
  }

  /**
   * Bring a product's pictures into the array shape, whatever it arrived in.
   *
   * Handles three states, because all three exist in real stores: a product
   * saved before this feature (imagePath + thumbnail), a product saved after it
   * (images[]), and a product with both because it was edited by an older build
   * after being saved by a newer one. The array wins where both are present and
   * disagree — it is the richer record — EXCEPT when it is empty, which is what
   * an older build writes when it drops a picture.
   */
  function normalise(product) {
    const p = product || {};
    let images = Array.isArray(p.images) ? p.images.filter(Boolean) : [];

    images = images.map((img, i) => ({
      id: img.id || imageId(p.id, i),
      path: img.path || '',
      thumbnail: img.thumbnail || '',
      kind: KIND_KEYS.includes(img.kind) ? img.kind : DEFAULT_KIND,
      caption: typeof img.caption === 'string' ? img.caption : '',
    })).filter((img) => img.path || img.thumbnail);

    // Nothing in the array but something in the legacy fields: this product has
    // not been migrated yet, or an older build just overwrote it.
    if (!images.length && (p.imagePath || p.thumbnail)) {
      images = [{
        id: imageId(p.id, 0),
        path: p.imagePath || '',
        thumbnail: p.thumbnail || '',
        // An image from before the split is UNLABELLED, not a render. Claiming
        // it shows a real printed part would be inventing a fact about a photo
        // nobody described; claiming it is a render would be too, and that one
        // at least cannot mislead a customer into expecting a photo.
        kind: DEFAULT_KIND,
        caption: '',
      }];
    }

    return {
      images,
      // The legacy view, kept in step. Empty when there are no pictures at all.
      imagePath: images[0] ? images[0].path : '',
      thumbnail: images[0] ? images[0].thumbnail : '',
    };
  }

  /**
   * Apply normalise() to a product object in place, returning it.
   *
   * Use this on LOAD, where the migration branch inside normalise() is the
   * point. Do not use it after a mutation — see syncView().
   */
  function apply(product) {
    if (!product) return product;
    const n = normalise(product);
    product.images = n.images;
    product.imagePath = n.imagePath;
    product.thumbnail = n.thumbnail;
    return product;
  }

  /**
   * Write the legacy view from the array, WITHOUT the migration branch.
   *
   * normalise() treats "empty array but imagePath set" as an unmigrated product
   * and rebuilds the array from the legacy field. That is right on load and
   * catastrophic after a delete: removing the last picture emptied images[],
   * left imagePath pointing at the file just unlinked, and the next normalise()
   * RESURRECTED the deleted image from it. Caught by the delete test, which is
   * the only place the two meanings of "empty" collide.
   */
  function syncView(product) {
    const imgs = Array.isArray(product.images) ? product.images : [];
    product.imagePath = imgs[0] ? imgs[0].path : '';
    product.thumbnail = imgs[0] ? imgs[0].thumbnail : '';
    return product;
  }

  /** Move an image to the front — the primary, used by the grid and storefront. */
  function makePrimary(product, id) {
    const p = apply(product);
    const i = p.images.findIndex((img) => img.id === id);
    if (i > 0) p.images.unshift(p.images.splice(i, 1)[0]);
    return syncView(p);
  }

  /** Remove one image. Returns the removed record so the caller can unlink the file. */
  function remove(product, id) {
    const p = apply(product);
    const i = p.images.findIndex((img) => img.id === id);
    if (i === -1) return null;
    const [gone] = p.images.splice(i, 1);
    syncView(p);
    return gone;
  }

  /** Set what a picture is. Unknown kinds are refused rather than stored. */
  function setKind(product, id, kind) {
    if (!KIND_KEYS.includes(kind)) return false;
    const p = apply(product);
    const img = p.images.find((x) => x.id === id);
    if (!img) return false;
    img.kind = kind;
    return true;
  }

  /**
   * Does this listing show the real thing?
   *
   * The question a customer is actually asking, and the one a shop should be
   * able to answer at a glance across its whole catalog.
   */
  function hasRealPhoto(product) {
    return normalise(product).images.some((img) => img.kind === 'print' || img.kind === 'detail');
  }


  /**
   * The pictures a storefront listing should carry, in order, within a budget.
   *
   * Lives here rather than inside the storefront modal's closure so it can be
   * tested: the modal is unreachable from an automation context, which meant
   * this logic shipped with no way to check it short of publishing a real
   * catalog to a real shop.
   *
   * BUDGETED per listing: three at 200 KB is roughly 600 KB each.
   *
   * That is NOT the whole story, and the version of this note that said it was
   * — "leaving room for forty listings without going near it" — reasoned from
   * the 25 MB request limit rather than the 8 MB cap the server puts on a
   * sanitised catalogue. Forty listings is 24 MB and would have been refused
   * outright. fitCatalogPhotos() budgets the catalogue as a whole; this
   * function only decides which three a listing would like to have.
   *
   * Ordered primary first, then any picture of the ACTUAL PRINT, then the rest:
   * if only one survives the budget it should be the one the shop chose, and if
   * two do, the second should be the honest one.
   *
   * ── IT PUBLISHES THE ORIGINAL, NOT THE GRID THUMBNAIL ──────────────────────
   *
   * `thumbnail` is 240px on its long edge. It is built for the product grid, it
   * is what this used to publish, and it was ALSO the hero image on the
   * storefront's product page — a 240px picture of a printed part, blown up.
   *
   * The full-resolution picture was never lost. It is written to disk on save
   * (`img.path`, ~1600px), and nothing ever read it back. So `opts.hero(img)`
   * hands back a web-sized rendition of that file and this prefers it, falling
   * back to the thumbnail whenever the file is gone, the product predates
   * per-image files, or the caller did not offer one — a small picture beats no
   * picture.
   *
   * `thumb` rides along so fitCatalogPhotos() can put it back when a catalogue
   * does not fit, and is stripped there before publish. It is present ONLY when
   * a hero was actually used — a photo that is already its own thumbnail has
   * nothing to fall back to, and the shape a caller sees is then exactly the
   * `{src, kind}` it has always been.
   */
  function storefrontPhotos(product, opts) {
    const o = opts || {};
    const perPhoto = Number.isFinite(o.perPhoto) ? o.perPhoto : 200000;
    const max = Number.isFinite(o.max) ? o.max : 3;
    const hero = typeof o.hero === 'function' ? o.hero : null;
    const usable = (v) => typeof v === 'string' && /^data:image\//.test(v);
    const all = normalise(product).images.filter((img) =>
      usable(img.thumbnail) && img.thumbnail.length <= perPhoto);
    if (!all.length) return [];
    const rest = all.slice(1);
    const ordered = [all[0], ...rest.filter((i) => i.kind === 'print'), ...rest.filter((i) => i.kind !== 'print')];
    return ordered.slice(0, max).map((img) => {
      /* The hero is not held to `perPhoto` — that budget is the size of a
       * thumbnail, and a hero that had to fit inside it would be a thumbnail
       * again. It IS held to PUBLISH_PHOTO_BYTES, which is the server's own
       * ceiling on one picture.
       *
       * Sending something over it does not fail: the server drops that photo
       * and stores the rest, so the publish succeeds and the picture is simply
       * gone. That is what happened, on the first real catalogue to use heroes —
       * a 262 KB primary image and the `photo` field with it, reported by the
       * consumer reading the payload rather than by anything here. A thumbnail
       * that arrives beats a photograph that does not. */
      const big = hero ? hero(img) : '';
      if (!usable(big) || big.length > PUBLISH_PHOTO_BYTES || big === img.thumbnail) {
        return { src: img.thumbnail, kind: img.kind };
      }
      return { src: big, kind: img.kind, thumb: img.thumbnail };
    });
  }

  /**
   * How big a published picture is, and how hard it is compressed.
   *
   * 1000px on the long edge, because the ceiling is the server's 8 MB cap on a
   * sanitised catalogue and every pixel is spent out of it. Measured on a real
   * 1600×1600 product photo, that lands around 260 KB once base64 has added its
   * third: FOUR TIMES the thumbnail's linear resolution, with eight photo-rich
   * listings still publishing all three of their pictures whole.
   *
   * Past that the catalogue does not fit, and fitCatalogPhotos() gives the
   * thumbnail back rather than taking the picture away.
   *
   * The original stays on disk at full size. This is what travels.
   */
  const HERO_MAX_DIM = 1000;
  const HERO_QUALITY = 0.82;

  /**
   * The largest single picture the server will store, and therefore the largest
   * one worth sending.
   *
   * MUST MATCH `isPhoto`'s ceiling in khayt-cloud (index.php and src/server.js).
   * A photo over it is not refused — it is DROPPED, and the rest of the
   * catalogue is stored, so the publish reports success and the picture is
   * simply missing. Anything checked here is a picture that cannot vanish
   * between this machine and a customer's screen.
   */
  const PUBLISH_PHOTO_BYTES = 400000;

  /**
   * The whole catalogue's photo budget, not one listing's.
   *
   * storefrontPhotos() budgets PER LISTING, and its own note reasoned about
   * "forty listings without going near it" against a limit that turned out not
   * to be the real one: the server caps a sanitised catalogue at 8 MB. Three
   * photos at 200 KB is 600 KB a listing, so a shop with about fourteen
   * photo-rich products stopped being able to publish AT ALL — 413, the whole
   * catalogue rejected, because of the pictures on some of it.
   *
   * A publish that goes through with fewer pictures beats a publish that does
   * not go through. So this trims rather than fails, and trims in the order
   * that costs the least: extra photos before anyone's only photo, and the
   * heaviest listing first, so one shop's 200 KB render does not cost forty
   * other listings their second picture.
   */
  const CATALOG_PHOTO_BUDGET = 7 * 1024 * 1024;   // 8 MB cap, 1 MB left for text

  function fitCatalogPhotos(items, maxBytes) {
    const budget = Number.isFinite(maxBytes) ? maxBytes : CATALOG_PHOTO_BUDGET;
    const list = Array.isArray(items) ? items : [];
    const withPhotos = list.filter((it) => it && Array.isArray(it.photos) && it.photos.length);
    const bytes = (it) => it.photos.reduce((n, p) => n + String(p.src || '').length, 0);
    let total = withPhotos.reduce((n, it) => n + bytes(it), 0);
    let dropped = 0;
    let downgraded = 0;

    /* Pass ZERO: give back the thumbnail before taking away the picture.
     *
     * Photos are published at ~1000px now rather than at the 240px grid
     * thumbnail, which is five times the linear resolution and roughly seven
     * times the bytes. Without this pass, making pictures better would make a
     * large catalogue publish FEWER of them — a listing that used to show a
     * poor photo would show none, and losing a picture is a worse outcome than
     * showing a small one.
     *
     * So a catalogue that does not fit gets shrunk first and thinned second,
     * heaviest listing first. Only once every picture is back to a thumbnail
     * and it still does not fit does anything get dropped.
     */
    while (total > budget) {
      const cand = withPhotos
        .flatMap((it) => it.photos)
        .filter((ph) => ph && ph.thumb && ph.src !== ph.thumb && String(ph.thumb).length < String(ph.src).length)
        .sort((a, b) => String(b.src).length - String(a.src).length)[0];
      if (!cand) break;
      total -= String(cand.src).length - String(cand.thumb).length;
      cand.src = cand.thumb;
      downgraded++;
    }

    // Pass one: extra photos, heaviest listing first. Nobody loses their only
    // picture while anyone else still has a spare.
    while (total > budget) {
      const cand = withPhotos.filter((it) => it.photos.length > 1)
        .sort((a, b) => bytes(b) - bytes(a))[0];
      if (!cand) break;
      total -= String(cand.photos.pop().src || '').length;
      dropped++;
    }
    // Pass two: only if a catalogue of single photos still does not fit. The
    // listing keeps its name, price and description and shows a placeholder.
    while (total > budget) {
      const cand = withPhotos.filter((it) => it.photos.length === 1)
        .sort((a, b) => bytes(b) - bytes(a))[0];
      if (!cand) break;
      total -= String(cand.photos.pop().src || '').length;
      dropped++;
    }

    /* `photo` IS NOT SENT. It is a view of photos[0], and the server derives it
     * from the gallery it stores — so putting it on the wire meant every
     * listing's primary photo travelled TWICE.
     *
     * Invisible while a photo was a 30 KB thumbnail. Now that it is a 200 KB
     * photograph it is half the payload, and it was uncounted: `bytes()` above
     * measures the gallery, so twenty single-photo listings measured 4 MB
     * against a 7 MB budget while putting 8 MB on the wire. That is a 413 and no
     * storefront at all — the exact failure this function exists to prevent.
     *
     * Deleted rather than left alone, because a caller that set it would
     * otherwise ship a picture the trim has already dropped. */
    for (const it of withPhotos) {
      delete it.photo;
      if (!it.photos.length) delete it.photos;
      // `thumb` was the fallback this function needed and is not part of what a
      // storefront receives. Sending it would put every picture on the wire
      // twice, which is the opposite of what the budget above is for.
      for (const ph of it.photos || []) delete ph.thumb;
    }
    return { dropped, downgraded, bytes: total, fits: total <= budget };
  }

  const api = { KINDS, KIND_KEYS, DEFAULT_KIND, normalise, apply, syncView, makePrimary, remove, setKind, hasRealPhoto, storefrontPhotos, fitCatalogPhotos, CATALOG_PHOTO_BUDGET, HERO_MAX_DIM, HERO_QUALITY, PUBLISH_PHOTO_BYTES, imageId };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytProductImages = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
