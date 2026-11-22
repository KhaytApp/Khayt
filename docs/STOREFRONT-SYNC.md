# Publishing a catalogue, and where it goes

One action publishes everything. There is no second form to fill in, and no
per-platform export.

**Settings → Storefront → Publish.** That writes one record in the cloud, and two
different things read it:

- the **public storefront page** a customer opens (`/shop/{shopId}`), and
- the **product feed** every other platform imports from (`/v1/shops/{shopId}/feed/{platform}`).

Both are built from the same published catalogue, so anything missing from one is
missing from the other for the same reason.

---

## What a publish carries

| | |
|---|---|
| Shop name, currency, note, lead time | from Settings |
| Minimum order, deposit %, tax rate, shipping | from the storefront form |
| Product name and description | **in both of your content languages** |
| Up to three photos per listing | each labelled — render, actual print, detail, scale, packaging |
| Price | **from the catalogue** |
| Print time, weight, material | **worked out from the product's parts** |

### The three specs are not typed twice

Khayt already knows how long a product takes on a machine, what it weighs and
what it is made of — print hours are what work out when a job can start. Those
travel with a publish, so a storefront that wants them does not send you back to
its admin to type each one again. A number typed in two places drifts, and then
both places look right.

**Print time is machine time only.** Preparation and finishing are published
separately, inside the lead time, so anything adding them here would count
finishing twice and quote later than you meant.

**Weight is print plus supports, times quantity** — the same grams the app takes
off your stock when the job completes, so the published figure and your own
deduction can never disagree.

A product with **no parts publishes nothing** for time and weight rather than a
zero. Zero reads as an answer — as *"prints instantly"* — and something nobody
has costed would be quoted same-day.

Dimensions are not published, because Khayt does not hold them.

### The price comes from the catalogue

The price box on the storefront form is an **override**, for the few items you
want priced differently there. Leave it empty and the item publishes at the price
the catalogue worked out — cost, margin, and whatever rounding or manual price
you set on the product.

This used to read the storefront box and nothing else, so a shop that had already
priced its whole catalogue published a storefront where everything cost nothing.
A deliberate `0` is still a price and is published as one.

### Both languages

A shop picks one or two of the nine languages Khayt speaks
(Settings → Preferences → *Product languages*). The catalogue declares which ones
it is written in, and the storefront page offers them: a visitor's `?lang=`, then
their browser's language, then the shop's first.

The page's own buttons and labels are still English and Arabic only. A shop
writing German gets German products under English chrome — a known limit, written
down here rather than discovered.

---

## Two surfaces, two spellings

Both are built from the same published catalogue, and they name their fields
differently on purpose:

| | `/v1/shops/{shopId}` — the catalogue | `/v1/shops/{shopId}/feed/{platform}` — the feed |
|---|---|---|
| what it is | Khayt's own record, what the storefront page reads | what another platform imports |
| convention | **camelCase** | **snake_case** |
| the three specs | `printHours` `weightGrams` `material` | `print_hours` `weight_grams` `material` |
| names | `name` `nameAr` `alt` | `title` `description` |
| price | `price` (string, shop's currency) | `price` + `currency` |

Neither is wrong. The catalogue is camelCase like every field already on it —
`nameAr`, `soldOut` — and the feed is snake_case because that is the convention
where these are read as product metadata.

**Written down here because the pair had never been.** An integrator built a
parser to the feed's names, pointed it at the catalogue, and would have dropped
both numbers silently — the value arrives, nothing errors, and the field is
simply missing for ever. Both spellings are pinned by tests in khayt-cloud now,
so neither can drift.

### The feed says which language it is in

The JSON feed carries `locale` and `locales` at the top, and a product carries
`translations` keyed by locale where the shop wrote a second language:

```json
{ "locale": "en", "locales": ["en", "ar"],
  "products": [{
    "title": "Portrait", "description": "A portrait",
    "translations": { "ar": { "title": "صورة الملك عبدالعزيز", "description": "صورة" } }
  }] }
```

**Keyed by locale, not suffixed.** A shop writes in one or two of nine
languages, so `title_ar` would need eight more spellings and would still not say
what the plain `title` is. Locale keys map straight onto a translation module.

`translations` is **absent** when a shop wrote only one language — never an
empty object. A catalogue published before `alt` existed carries `nameAr` alone,
which becomes a title-only `ar` entry: no description, because an empty one
would overwrite a real translation on import.

This is JSON only. CSV and XML feeds are the shapes their platforms define, and
neither has a place to put a second language.

### `material` is a list

One string, comma-joined, when a product mixes filaments: `"PLA+ 2.0, TPU"`.
Distinct, in the order the shop listed the parts. A consumer combining materials
across an order has to **split on the comma before de-duplicating** — whole-string
de-duplication turns `"PLA+ 2.0, TPU"` and `"TPU"` into
`"PLA+ 2.0, TPU, TPU"`.

### `photo` is derived, not sent

A listing carries `photos[]`, up to three, each labelled. `photo` is a view of
`photos[0]` for pages written before the gallery existed — **the server derives
it** from the gallery it stores, so it can never point at a picture the gallery
does not have. Read `photos[]`; fall back to `photo` only when there is no
gallery at all.

### One picture is capped at 400 KB

A photo larger than that is **dropped, not refused** — the rest of the catalogue
stores and the publish reports success. The app will not send one, so this
matters only to something publishing to the API directly.

---

## Feed URLs

**Settings → Integrations → Copy feed link**, per platform. The format follows the
platform:

| Platform | Format |
|---|---|
| Shopify, WooCommerce, PrestaShop, Shopware, and the CN/JP marketplaces | CSV |
| Google, Meta / Facebook / Instagram | XML (Google Merchant fields) |
| anything else | JSON |

`?format=csv\|xml\|json` overrides it.

### Images are real URLs

`/v1/shops/{shopId}/feed-image/{itemId}/{n}` — served straight out of the
published catalogue, public and unauthenticated, because a feed is only useful if
the platform importing it can fetch the picture without credentials. `n` is
optional and means the primary photo.

Every feed used to publish an **empty** image for every product: the emitters
printed a photo only when it was already an `http` URL, and a catalogue photo is
a data URI. Nothing a shop photographed reached any platform. Labelled extras are
published as `additional_image_link` where the platform takes them, so the shot
of the *actual printed part* travels with the listing.

Unpublishing takes the pictures down with it — they are served from the published
catalogue, not from separate storage.

#### `?v=` is the picture; the path is only the slot

The URL ends `?v=<12 hex>`, a hash of **that photograph's own bytes**. It is not
decoration and it is not the catalogue's version:

- **Replace a photo and republish, and its URL changes.** The path alone —
  `/feed-image/{item}/0` — names a *slot*, so before this it was byte-identical
  before and after, and nothing downstream could tell that anything had happened.
  Two things were relying on that and both were wrong: the route cached for an
  hour on the reasoning that "the URL changes with the item it belongs to" (which
  is identity, not content), and the Medusa subscriber deliberately does not
  re-push images on a URL that has not changed — so a shop that replaced a
  product photograph went on showing the old one.
- **Republish an unchanged photo and its URL does not change**, and neither does
  any other picture on the listing when one of them is replaced. A version over
  the whole catalogue would expire every image every six hours, which is how
  versioning gets abandoned for a purge button.

A consumer that stores these URLs can therefore compare them: **a URL that has
not changed is a picture that has not changed.**

The picture also carries an `ETag` now, so asking whether it changed no longer
means downloading it — it was the largest payload in the cloud and the only one
a cache could not revalidate. A URL carrying the current `v` is served
`immutable` for a year; one without it, or with an old one, is short-lived and
**still serves the current picture**. An address stored before any of this
existed is an old URL, not a wrong one, and it heals on the next request.

### Size

A published catalogue is capped at **8 MB** after sanitising. Three photos at
200 KB is 600 KB a listing, so Khayt trims photos to fit rather than failing the
publish: spare photos go before any listing's only one, heaviest listing first. A
storefront with fewer pictures is a storefront; a `413` is not.

---

## Medusa

Medusa is **inbound only** — `dir: ['in']` in the integrations registry, the one
storefront in the directory without `'out'`. It is a self-hosted framework rather
than a hosted store, so it has no webhook settings to paste a URL into: orders
reach Khayt through a subscriber file you install in your own project
(Settings → Integrations offers the code; see `lib/medusa-subscriber.js`).

**There is no catalogue push to Medusa.** But the feed does not care what is
asking for it, and unmapped platforms default to JSON:

```
GET https://cloud.khaytapp.com/v1/shops/{shopId}/feed/medusa
```

A Medusa project can pull that on a schedule. It is the same public,
read-only feed every other platform uses.

---

## If something is missing from a listing

Almost always one of these, and each is visible in the app before you publish:

- **No price** — the product has no cost yet (no parts, or parts with no weight),
  so there is nothing to compute from.
- **No image** — the product has no photos in the catalogue. The storefront
  publishes what the product carries.
- **No description** — descriptions are per language now; an empty one publishes
  empty and imports blank wherever it goes.
- **Nothing at all** — the catalogue has not been republished since the change
  you are looking for. The feed is built from the stored payload, so it shows
  what was last pushed, not what is on screen.
