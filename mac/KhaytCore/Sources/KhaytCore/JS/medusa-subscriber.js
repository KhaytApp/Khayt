'use strict';

(function (global) {
/**
 * The Medusa subscriber Khayt hands a shop to paste into its own project.
 *
 * WHY THIS FILE EXISTS AT ALL
 *
 * Every other storefront in the directory is served by one button: copy an
 * import link, paste it into the store's webhook settings, done. Medusa has no
 * webhook settings. It is a self-hosted framework, not a hosted store, and its
 * `order.placed` event is delivered in-process to a *subscriber* — a file in the
 * shop's own repository — carrying `{ id }` and nothing else (verified against
 * Medusa's own subscriber documentation, not inferred).
 *
 * So for Medusa, "Copy import link" on its own is a URL with nowhere to go. The
 * shop has to write the POST, and to write it they have to know that the event
 * gives them an id rather than an order and that they must fetch the rest
 * themselves. Handing them the finished file is the difference between Medusa
 * being supported and Medusa being listed.
 *
 * Kept out of the renderer and out of a docs page so it is one artefact with one
 * test, rather than a snippet in a markdown file that drifts from the mapper it
 * has to feed.
 *
 * WHAT THE FIELD LIST IS FOR
 *
 * `fields` is not decoration. Medusa marks `items`, `shipping_address`,
 * `billing_address` and `customer` as @expandable: a graph query that does not
 * ask for them returns an order without them, and the intake would arrive with
 * no customer name and no line items — which is exactly what a shop would report
 * as "Khayt imported an empty order".
 *
 * Every field here is one the mapper in khayt-cloud reads, with one deliberate
 * exception: `currency_code` is requested and not read. It is kept because an
 * order's amounts are meaningless without it and the mapper is the only thing
 * that does not need it yet — but it is named as an exception rather than left
 * to look like the rule, since this comment used to claim the list had none.
 *
 * The reverse mistake is the one that actually bit: two fields the mapper DOES
 * read were missing from this list, so their fallbacks could never fire. See
 * `custom_display_id` and `items.detail.*` below.
 */

/** The subscriber's canonical filename inside the shop's Medusa project. */
const SUBSCRIBER_PATH = 'src/subscribers/khayt-order-placed.ts';

/**
 * Fields the import mapper reads. Keep in step with the `medusa` branch of
 * `mapPlatformOrder` — a field dropped here arrives as a blank there.
 */
const FIELDS = [
  'id',
  'display_id',
  // The mapper's ref falls back to this when `display_id` is empty, and it was
  // never requested — so the fallback could not fire and the ref fell through
  // to the raw `id` instead of the number the shop says out loud. A fallback
  // that cannot be reached is worse than no fallback: the code reads as though
  // the case is handled.
  'custom_display_id',
  'email',
  'currency_code',
  'metadata',
  /* PAID OR NOT. Not a column: Medusa works it out from the payment
   * collections in `getOrderDetailWorkflow`, which is why the subscriber below
   * reads the order through that workflow rather than a bare `query.graph`. A
   * bare graph query accepts the name and answers undefined, for ever. Khayt
   * Cloud turns captured / authorized / partially_captured into `paid`, but
   * only on an import that carries the shop's import key. */
  'payment_status',
  'items.*',
  /* THE PRODUCT, for two things the line item does not carry.
   *
   * `material` is a product column the line-item DTO does not denormalise
   * (it copies product_title, product_description, product_subtitle, and not
   * that), so `items.*` sends nothing for it, for ever, silently. The
   * integrator running the first real Medusa storefront found this by checking
   * against a freshly migrated database rather than trusting the DTO's types.
   * It is folded onto each line's `metadata.material` below, because that is
   * where Khayt's importer reads it.
   *
   * `external_id` (and `metadata.khayt_id`) is where the storefront's product
   * sync keeps Khayt's own catalogue id, so a line is matched to the product
   * it IS rather than to whatever shares its title. This used to be
   * `items.product.material` alone; `.*` is the product's own columns and
   * covers both. */
  'items.product.*',
  /* The customer's CHOICE — colour, size — as option title → value. `x.*`
   * does not expand a nested relation, so each level is named: the variant,
   * its option values, and the option each value belongs to (which is where
   * the title "Colour" lives). Without these a line arrives as a name, and a
   * red dragon and a blue one are the same job. */
  'items.variant.*',
  'items.variant.options.*',
  'items.variant.options.option.*',
  // `items.*` selects the line item's OWN columns and does NOT expand a nested
  // relation — Medusa's own shipped subscriber lists `items.product.is_giftcard`
  // explicitly alongside `items.*` for exactly that reason. The mapper reads
  // `it.detail.quantity` as its quantity fallback, so `detail` has to be asked
  // for by name or that fallback is dead too.
  'items.detail.*',
  'shipping_address.*',
  'billing_address.*',
  'customer.*',
];

/**
 * Render the subscriber with the shop's own import URL baked in.
 *
 * @param {string} importUrl  e.g. https://cloud.khaytapp.com/v1/shops/abc/import/medusa
 * @returns {string} TypeScript source, ready to save at SUBSCRIBER_PATH
 */
function subscriberSource(importUrl) {
  // A URL is about to be embedded in a double-quoted TS string literal. It is
  // the app's own cloud URL rather than anything a stranger supplies, but "it
  // came from our own settings" is how injection bugs are argued for, so the two
  // characters that could end the literal are escaped rather than trusted.
  const url = String(importUrl || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/[\r\n]/g, '');

  return `// ${SUBSCRIBER_PATH}
//
// Sends every placed order to Khayt, which files it under Order requests.
// Generated by Khayt — the URL below is your shop's import link.
//
// Two environment variables, both optional, both read from your Medusa
// server's environment (restart it after setting either):
//
//   KHAYT_IMPORT_KEY  Your shop's import key, from Khayt → Integrations →
//                     Import key. With it Khayt trusts the order's payment
//                     status and prices, so a paid order becomes a job by
//                     itself. Without it the order still arrives, but as a
//                     request for a person to look at: the import link is
//                     public, so Khayt will not take "paid" from anyone who
//                     cannot prove they are you. Once the shop HAS a key,
//                     Khayt refuses orders sent without it.
//   MEDUSA_ADMIN_URL  Each order request then links back to the order in your
//                     admin.
//
// The key is never written into this file: it is a secret, and this file
// lives in your repository.
import type { SubscriberArgs, SubscriberConfig } from "@medusajs/framework"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"
import { getOrderDetailWorkflow } from "@medusajs/medusa/core-flows"

const KHAYT_IMPORT_URL = "${url}"
const KHAYT_IMPORT_KEY = (process.env.KHAYT_IMPORT_KEY ?? "").trim()
// Optional. Set it and each Order request carries a link straight back to the
// order in your admin. Khayt cannot derive this — your admin lives wherever you
// host it. Khayt refuses anything that is not http(s) when it opens the link.
const MEDUSA_ADMIN_URL = process.env.MEDUSA_ADMIN_URL ?? ""

// Said once per start rather than on every order, so it is seen and not
// drowned out.
let saidNoKey = false

export default async function khaytOrderPlaced({
  event: { data },
  container,
}: SubscriberArgs<{ id: string }>) {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)

  if (!KHAYT_IMPORT_KEY && !saidNoKey) {
    saidNoKey = true
    logger.warn("Khayt: KHAYT_IMPORT_KEY is not set, so Khayt will not trust these orders' payment status. They arrive as requests to review rather than as paid jobs.")
  }

  // order.placed carries the order's ID and nothing else, so fetch the rest.
  // Every field below is one Khayt reads — items and the addresses are
  // expandable, and omitting them imports an order with no lines and no name.
  //
  // Through Medusa's own order-detail workflow rather than a bare query:
  // payment_status is not a column, and only this works it out.
  let order: any
  try {
    const { result } = await getOrderDetailWorkflow(container).run({
      input: {
        order_id: data.id,
        fields: [
${FIELDS.map((f) => `          "${f}",`).join('\n')}
        ],
      },
    })
    order = result
  } catch (e: any) {
    if (e?.type === "not_found") {
      logger.warn(\`Khayt: order \${data.id} vanished before it could be sent\`)
      return
    }
    throw e
  }

  /* Trim each line to what Khayt reads.
   *
   * The product's material is folded onto the line's metadata, and a line's
   * own \`metadata.material\` WINS where both exist, so a bespoke commission can
   * carry a material the catalogue product does not. Of the product, only the
   * ids that match the line to Khayt's catalogue are sent; of the variant,
   * the chosen options as title → value.
   */
  const { payment_collections, fulfillments, ...rest } = order
  const payload = {
    ...rest,
    metadata: { ...(order.metadata ?? {}), ...(MEDUSA_ADMIN_URL ? { admin_url: \`\${MEDUSA_ADMIN_URL.replace(/\\/+$/, "")}/orders/\${order.id}\` } : {}) },
    items: (order.items ?? []).map(({ product, variant, ...line }: any) => ({
      ...line,
      metadata: { ...(line.metadata ?? {}), material: line.metadata?.material ?? product?.material ?? undefined },
      product: product ? { external_id: product.external_id ?? undefined, metadata: product.metadata?.khayt_id ? { khayt_id: product.metadata.khayt_id } : undefined } : undefined,
      variant: variant ? {
        id: variant.id, title: variant.title, sku: variant.sku,
        options: (variant.options ?? []).map((o: any) => ({ value: o?.value, option: { title: o?.option?.title } })),
      } : undefined,
    })),
  }

  try {
    const res = await fetch(KHAYT_IMPORT_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        // A header rather than a query parameter, so the key stays out of logs.
        ...(KHAYT_IMPORT_KEY ? { "X-Khayt-Import-Key": KHAYT_IMPORT_KEY } : {}),
      },
      body: JSON.stringify(payload),
    })
    /* THROW, so Medusa retries. The import endpoint deduplicates on
     * \`medusa:#\${display_id}\`, answers 200 to a repeat with
     * \`{"duplicate": true}\`, and only notifies the shop on a genuine first
     * delivery — so a retry cannot become a second order request.
     *
     * This used to swallow failures, back when that guarantee did not exist.
     * Swallowing means a failed import reaches a log and nothing else; throwing
     * means Medusa keeps trying until it lands. */
    if (res.status === 401) {
      throw new Error(\`Khayt: import refused order \${order.display_id ?? order.id} — your shop has an import key, and KHAYT_IMPORT_KEY is missing or out of date on this server. Set it and restart.\`)
    }
    if (!res.ok) {
      throw new Error(\`Khayt: import returned \${res.status} for order \${order.display_id ?? order.id}\`)
    }
  } catch (e) {
    logger.error(\`Khayt: could not reach the import endpoint — \${e}\`)
    throw e
  }
}

export const config: SubscriberConfig = {
  event: "order.placed",
}
`;
}

const api = { subscriberSource, SUBSCRIBER_PATH, FIELDS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMedusa = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
