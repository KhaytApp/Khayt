'use strict';

/**
 * What happens to a job when its stage changes.
 *
 * A status change in Khayt is not a field write. Moving an order to
 * `completed` stamps `completedAt`, settles the hold it may have been sitting
 * in, deducts the filament and the packaging it consumed, fixes the cost basis
 * the job will be judged on ever after, and can move a customer into a new
 * loyalty tier. Moving it *back out* of completed has to undo enough of that
 * for the reprint to behave like a fresh job. These rules lived in
 * `renderer/order-flows.js`, tangled with `printLog`, `settings`, `toast()`
 * and four `render*()` calls, which put them out of reach of anything that is
 * not the Electron renderer.
 *
 * The Mac app's board can show where the work is piling up but cannot let you
 * move a card, because the only place that knows what moving a card means is a
 * renderer it does not run. The alternative — a Swift reimplementation of the
 * most consequential write in the app — is how two apps come to disagree about
 * whether a job is finished.
 *
 * So the rules moved here and take their context as an argument.
 *
 * ── WHAT IS HERE AND WHAT IS NOT ───────────────────────────────────────────
 * `gate()` answers "may this move happen at all", and is the only part a
 * read-only caller needs: it is what greys out a drop target.
 *
 * `apply()` performs the change **on the order it is handed**, in place, and
 * returns the things it cannot do itself:
 *
 *   - `notices` — sentences the person should see (message codes, not text;
 *     the caller looks them up in its own catalogue).
 *   - `effects` — an ORDERED list of everything that must happen outside this
 *     order: saving, rendering, the money deductions, the notifications, the
 *     webhooks. A host performs the ones it has and ignores the rest. The Mac
 *     app has no Telegram; it should still be able to move a job.
 *
 * Mutating in place rather than returning a copy is deliberate. `printLog`
 * holds the same object an open modal is holding, and a lift that quietly
 * swapped the identity of an order would break the callers it was meant to
 * leave alone.
 *
 * PURE: no globals of its own, and **no clock** — `ctx.now` is the current
 * time in milliseconds, so a test can put a job on hold for nine days without
 * waiting. `KhaytAssembly` is consulted through a `typeof` guard the way
 * `order-flows.js` consulted it, because it is a sibling `lib/` module present
 * in both apps and a build without it must behave as it did before.
 *
 * ── ONE ORDERING CHANGE, AND WHY IT IS INERT ───────────────────────────────
 * The original computed `costBasis` *between* deducting filament and deducting
 * packaging. Here both deductions are effects the caller runs after `apply()`
 * returns, so `costBasis` is now fixed before either. This is safe only
 * because `deductFilamentForOrder` neither reads nor writes `costBasis` or any
 * part's `baseCost` — it reads grams and spool ids and sets
 * `order.materialDeducted`. Checked, not assumed. If that ever stops being
 * true, this comment is the thing that was wrong.
 */
(function (global) {

  /** A job remembers its last two hundred moves and no more. */
  const HISTORY_CAP = 200;

  /** How many random bytes a survey token is made of. */
  const SURVEY_TOKEN_BYTES = 12;

  const MS_PER_DAY = 86400000;

  const ctxOfStatus = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});

  const assemblyApi = () =>
    (typeof globalThis !== 'undefined' ? globalThis.KhaytAssembly : undefined);

  /** `lib/order-email.js`, the same way and for the same reason. */
  const emailApi = () =>
    (typeof globalThis !== 'undefined' ? globalThis.KhaytOrderEmail : undefined);

  /** `lib/portal-refresh.js`, ditto. */
  const portalApi = () =>
    (typeof globalThis !== 'undefined' ? globalThis.KhaytPortalRefresh : undefined);

  /** `YYYY-MM-DD` in the machine's own timezone — a due date is a local day. */
  function localDateStr(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  /**
   * True when moving `orderId` into `newStatus` would meet or exceed the
   * configured WIP limit for that column.
   *
   * Finished columns are never limited: a limit exists to stop work being
   * started, not to stop it being finished.
   */
  function wouldExceedWipLimit(orders, orderId, newStatus, wipLimits) {
    if (!newStatus || newStatus === 'completed' || newStatus === 'delivered' || newStatus === 'quote') return false;
    const limit = (wipLimits || {})[newStatus] || 0;
    if (limit <= 0) return false;
    const colCount = (orders || []).filter(o => o.id !== orderId && o.status === newStatus).length;
    return colCount >= limit;
  }

  /**
   * May this order move to `newStatus`?
   *
   * `ctx`: `{ orders, settings }`. Returns `{ ok, block, warn, needsActuals }`.
   * `block` and `warn` are `{ code, params }` — message codes, because this
   * module does not know which language the shop reads. Every reason carries a
   * `params` object even when it is empty, so a typed caller decodes one shape
   * rather than two.
   *
   * A soft WIP warning survives a later block on purpose: the original showed
   * both toasts, and being told "this column is full AND the assembly is not
   * finished" is more useful than being told one of the two.
   */
  /**
   * The two spellings of finished.
   *
   * ── WHY THIS IS A NAMED THING AND NOT A COMPARISON ────────────────────────
   *
   * Khayt wrote `delivered` before it wrote `completed` with a `deliveredAt`
   * beside it, and both are still in shops' books — thirteen of them in the
   * sample. So "is this job finished" is a two-value test, and it was written
   * out by hand in at least eight modules.
   *
   * Written out by hand is written out wrongly eventually, and it was: the
   * machine P&L and the machine revenue chart both filtered `status ===
   * 'completed'` alone, in BOTH apps, so every job a shop had marked delivered
   * was missing from what its printers had earned. Nothing threw; the chart
   * just quietly described a subset.
   *
   * One name, exported, so the next caller has something to reach for.
   */
  const FINISHED_STATUSES = ['completed', 'delivered'];

  function isFinished(order) {
    const st = order && order.status;
    return st === 'completed' || st === 'delivered';
  }

  function gate(order, newStatus, ctx) {
    const c = ctx || {};
    const settings = c.settings || {};
    const orders = Array.isArray(c.orders) ? c.orders : [];
    const wipLimits = settings.wipLimits || {};

    // Production paused stops work being STARTED, and nothing else. A paused
    // shop still finishes and still ships what it already printed.
    if (settings.productionPaused && newStatus === 'printing') {
      return { ok: false, block: { code: 'production_paused', params: {} }, warn: null, needsActuals: false };
    }

    let warn = null;
    if (newStatus !== 'completed' && wouldExceedWipLimit(orders, order && order.id, newStatus, wipLimits)) {
      const params = { col: newStatus, n: wipLimits[newStatus] };
      if (settings.wipEnforceHardLimit) {
        return { ok: false, block: { code: 'wip_blocked', params }, warn: null, needsActuals: false };
      }
      warn = { code: 'wip_reached', params };
    }

    // BOM assemblies: every printed part must pass QC and the owner must tick
    // "Assembled" before the order can complete. Orders with no components[]
    // are unaffected.
    const A = assemblyApi();
    if (newStatus === 'completed' && A && A.isAssembly(order)) {
      const g = A.canCompleteAssembly(order);
      if (!g.ok) {
        const names = (g.remaining || []).map(r => (r && r.name) || '?');
        const block = g.reason === 'not_assembled'
          ? { code: 'assembly_not_assembled', params: {} }
          : { code: 'assembly_parts', params: { parts: names.join(', '), count: names.length } };
        return { ok: false, block, warn, needsActuals: false };
      }
    }

    // Completing a job is the moment the shop learns what it really cost, so
    // it is also the moment worth asking for the actual time and grams.
    return { ok: true, block: null, warn, needsActuals: newStatus === 'completed' };
  }

  /** The current run is over: the clock, the pause and the paused total. */
  function stopTimer(order) {
    if (!order.timerStart) return;
    delete order.timerStart;
    delete order.timerPausedAt;
    delete order.timerPausedMs;
  }

  function pushHistory(order, status, atIso) {
    if (!order.statusHistory) order.statusHistory = [];
    order.statusHistory.push({ status, at: atIso });
    if (order.statusHistory.length > HISTORY_CAP) {
      order.statusHistory = order.statusHistory.slice(-HISTORY_CAP);
    }
  }

  /**
   * Clear on-hold state when an order leaves `on_hold`, and — unless it is
   * being finished — push the due date out by the days it spent waiting.
   *
   * A job held for nine days is not late by nine days; the shop was not
   * working on it. A job *completed* out of hold needs no new due date at all,
   * which is why the extension is skipped there but the cleanup is not: a
   * direct hold → completed used to leave `heldAt` behind for ever.
   */
  function resumeFromHold(order, prevStatus, newStatus, nowMs, notices) {
    if (prevStatus === 'on_hold' && newStatus !== 'on_hold') {
      if (newStatus !== 'completed' && newStatus !== 'delivered' && order.dueDate && order.heldAt) {
        const holdDays = Math.ceil((nowMs - new Date(order.heldAt).getTime()) / MS_PER_DAY);
        if (holdDays > 0) {
          const d = new Date(order.dueDate + 'T00:00:00');
          d.setDate(d.getDate() + holdDays);
          order.dueDate = localDateStr(d);
          notices.push({ code: 'due_extended', params: { days: holdDays, date: order.dueDate } });
        }
      }
      delete order.holdReason;
      delete order.heldAt;
    } else if (newStatus === 'pending' && order.holdReason !== undefined) {
      delete order.holdReason;
      delete order.heldAt;
    }
  }

  /**
   * Move `order` to `newStatus`, in place.
   *
   * `ctx`: `{ now, inventory, holdReason, qc }`. Call `gate()` first —
   * `apply()` assumes the move has already been allowed, and a caller that
   * skips the gate has decided to skip it. `holdReason` is read only when
   * moving to `on_hold`, and only when the key is present at all; `qc` only
   * when moving to `completed`.
   *
   * Returns `{ prevStatus, notices, effects }`. Run the effects in the order
   * they are given; that order is the original's, and some of it matters (the
   * loyalty tier must be read before the save, the webhooks after it).
   */
  function apply(order, newStatus, ctx) {
    const c = ctx || {};
    const nowMs = typeof c.now === 'number' ? c.now : Date.now();
    const nowIso = new Date(nowMs).toISOString();
    const inventory = Array.isArray(c.inventory) ? c.inventory : [];
    const prevStatus = order.status;
    const notices = [];
    const effects = [];

    /* A QUOTE THAT LEAVES THE QUOTE COLUMN HAS BEEN ACCEPTED.
     *
     * `quoteAcceptedAt` was written by exactly one path — the Approve button
     * in the invoicing screen — while a shop that simply drags the card to
     * Pending, or picks Pending from the Job menu, moved it without stamping
     * anything. The field is what the quote conversion rate is computed from
     * (`quotesCreated.filter(o => o.quoteAcceptedAt)`), so every quote won by
     * dragging counted as a quote never accepted, and a shop that works from
     * the board saw a conversion rate that only ever fell.
     *
     * Stamped only when it is not already set, so the Approve button's own
     * date — and a customer's approval through the portal, which stamps the
     * day they clicked — both survive. A quote CANCELLED is not accepted.
     */
    if (prevStatus === 'quote' && newStatus !== 'quote' && newStatus !== 'cancelled'
        && !order.quoteAcceptedAt) {
      order.quoteAcceptedAt = nowIso.split('T')[0];
    }

    if (newStatus === 'completed') {
      resumeFromHold(order, prevStatus, 'completed', nowMs, notices);
      pushHistory(order, 'completed', nowIso);
      order.status = 'completed';
      if (!order.completedAt) order.completedAt = nowIso;

      // A job that passed inspection says so ON THE ORDER, and it has to,
      // because `qcStatusOf` reads exactly these fields and `computeQcMetrics`
      // counts only the orders it can answer for. A completion that skipped
      // them is not counted as failed — it is not counted at all, so a shop's
      // pass rate is quietly computed over a shrinking subset of its work.
      //
      // Only a PASS is recorded here. A failure is a different journey — a
      // waste entry, a defect, a decision about scrapping or reprinting — and
      // it does not end in `completed`.
      const qc = c.qc;
      if (qc && qc.outcome === 'pass') {
        order.qcStatus = 'pass';
        order.qcAt = nowIso;
        order.qcPassedAt = nowIso;
        order.qcNotes = qc.notes || null;
        // Assigned even when nobody was named: a shop that turns its inspector
        // roster off should not keep the last inspector on every later job.
        order.inspector = qc.inspector || null;
      }

      // The timer stops when the print does. It used to survive a completion —
      // nothing DISPLAYS it, because the badge is drawn only for a printing job,
      // but "is this job's timer running" then could not be answered by looking
      // at the job, and the value sat there until some later move cleared it.
      stopTimer(order);
      // What the job cost is fixed the moment it is finished. Recomputing it
      // later from today's filament prices would rewrite last year's margins.
      if (!order.costBasis) {
        order.costBasis = (order.parts || []).reduce((s, p) => s + (+p.baseCost || 0), 0);
      }

      effects.push({ type: 'deduct_filament' });
      effects.push({ type: 'deduct_packaging' });
      effects.push({ type: 'save' });
      // Finishing a job can move its customer up a tier. No customer, no tier —
      // and the caller must have read the OLD tier before calling apply(),
      // because by now the job is already finished.
      if (order.clientId) effects.push({ type: 'tier_check' });
      effects.push({ type: 'render', dashboard: true });
      effects.push({ type: 'toast_updated' });
      if (order.clientId) effects.push({ type: 'export_status_page' });
      effects.push({ type: 'telegram', status: 'completed' });
      // Fired once per completion and once only — the webhooks are not
      // idempotent, and a shop's ERP counting a job twice is a real invoice.
      effects.push({ type: 'webhook', event: 'status_changed', newStatus: 'completed' });
      effects.push({ type: 'order_webhook', event: 'status' });
      effects.push({ type: 'webhook', event: 'order_delivered' });
      if (!order.surveyToken) effects.push({ type: 'ensure_survey_token' });
      effects.push({ type: 'republish_portal' });
      return { prevStatus, notices, effects };
    }

    order.status = newStatus;
    pushHistory(order, newStatus, nowIso);
    effects.push({ type: 'activity_log', text: `${order.id} → ${newStatus}` });

    // Re-opening a finished order: clear the completion state so the print
    // timer and the material deduction behave like a fresh job. A stale
    // printingStartedAt skews every elapsed and ETA figure afterwards, and
    // without clearing materialDeducted the reprint consumes nothing.
    if ((prevStatus === 'completed' || prevStatus === 'delivered') &&
        newStatus !== 'completed' && newStatus !== 'delivered') {
      delete order.completedAt;
      delete order.materialDeducted;
      delete order.printingStartedAt;
    }

    // A resin job entering post-processing needs somewhere to record the wash
    // and the cure. Decided from the spool, not from the order, because
    // nothing asks the shop to declare a job "resin".
    if (newStatus === 'post') {
      const invItem = inventory.find(i =>
        i.id === order.filamentId || (order.parts || []).some(p => p.filamentId === i.id));
      if (invItem && invItem.materialType === 'resin') {
        order.isResin = true;
        if (!order.resinPost) {
          order.resinPost = {
            washDurationMins: null, washIpaVolumeMl: null,
            cureDurationMins: null, curePowerW: null,
            inspectionNotes: '', completedAt: null,
          };
        }
      }
    }

    // A job put on hold remembers WHEN, because that is the whole basis of the
    // due date it gets back. Without it a job held for nine days resumes with
    // its original due date and is late through nobody's fault — and the code
    // that would have extended it looks at `heldAt`, finds nothing, and does
    // nothing, silently.
    //
    // Only stamped when it is not already set: a caller that recorded the hold
    // itself (Bed Ready's queue does, before it calls in) keeps its own moment.
    if (newStatus === 'on_hold') {
      if (!order.heldAt) order.heldAt = nowIso;
      // A reason is optional — a shop that just needs the job out of the way
      // should not have to invent one — but "no reason given" has to be stored
      // as such rather than left as whatever the last hold said.
      if (Object.prototype.hasOwnProperty.call(c, 'holdReason')) {
        order.holdReason = c.holdReason || null;
      }
    }

    // The live timer runs while the job is printing and not a moment longer.
    // printingStartedAt is the FIRST start and survives a pause; timerStart is
    // the current run.
    if (newStatus === 'printing') {
      order.timerStart = nowIso;
      if (!order.printingStartedAt) order.printingStartedAt = nowIso;
    } else {
      stopTimer(order);
    }

    resumeFromHold(order, prevStatus, newStatus, nowMs, notices);

    effects.push({ type: 'save' });
    effects.push({ type: 'render', dashboard: false });
    effects.push({ type: 'toast_updated_undoable' });
    if (order.clientId) effects.push({ type: 'export_status_page' });
    effects.push({ type: 'email', status: newStatus });
    effects.push({ type: 'telegram', status: newStatus });
    effects.push({ type: 'webhook', event: 'status_changed', newStatus });
    effects.push({ type: 'order_webhook', event: 'status' });
    effects.push({ type: 'republish_portal' });
    return { prevStatus, notices, effects };
  }

  /**
   * Which column a job belongs in.
   *
   * DELIVERED IS NOT A STATUS. A handed-over job stays `completed` and carries
   * a `deliveredAt` — `renderer/kanban.js` builds its Delivered column from
   * exactly that pair, and `markDelivered` deliberately does not move the
   * status, because moving it would empty the column the button feeds.
   *
   * The rule lived only inside the kanban's own grouping loop, so anything else
   * asking "which column is this job in" — the Mac app's board, most recently —
   * read `status` and put every delivered job under Completed.
   *
   * `split` is returned as itself. A split parent has been replaced by the
   * sub-orders that carry its price between them; it is not work anyone does,
   * and a caller has to decide what to do about it rather than have it quietly
   * filed under `pending`.
   */
  function stageOf(order) {
    if (!order) return null;
    const status = order.status;
    // Delivered is asked first because it is the later of the two: a job that
    // was shipped and has since arrived is delivered, not still in transit.
    if (status === 'completed' && order.deliveredAt) return 'delivered';
    if (status === 'completed' && order.shippedAt) return 'shipped';
    return status || null;
  }

  /**
   * The shipping statuses that mean the parcel has left the shop.
   *
   * `label_created` is NOT one of them. A printed label is a parcel still on
   * the bench, and a shop that prints labels in the morning would otherwise
   * see every one of them move to Shipped before anything was collected.
   */
  const IN_THE_POST = ['in_transit', 'out_for_delivery', 'delivered'];

  /**
   * What a carrier's tracking says, written onto the job.
   *
   * Three places stamped `deliveredAt` from a carrier event by hand — the
   * shipping dialog, and the webhook handler twice, once before its write and
   * once inside it. Adding `shippedAt` to each of them would have made six
   * copies of a rule with no test, so it is one function with one.
   *
   * A parcel that has arrived was also, at some point, posted: a job that
   * reaches `delivered` without ever reporting `in_transit` gets both stamps,
   * because a delivered job that was never shipped is a hole in its own
   * history. Neither stamp is ever moved once written — the first time the
   * shop heard it is the answer, and a later event is the carrier catching up.
   *
   * Returns true when something changed, so a caller can skip a write.
   */
  function stampFromShipping(order, shippingStatus, nowIso) {
    if (!order || order.status !== 'completed') return false;
    const at = nowIso || new Date().toISOString();
    let changed = false;
    if (IN_THE_POST.indexOf(shippingStatus) !== -1 && !order.shippedAt) {
      order.shippedAt = at;
      changed = true;
    }
    if (shippingStatus === 'delivered' && !order.deliveredAt) {
      order.deliveredAt = at;
      changed = true;
    }
    return changed;
  }

  /**
   * Send a finished job out.
   *
   * SHIPPED IS NOT A STATUS EITHER, for the same reason `delivered` is not. A
   * job in the post is finished work: it has been made, it cost what it cost,
   * and it earned what it earned. Giving it a status of its own would take it
   * out of every "finished" set in both apps — revenue, the P&L, the VAT
   * return, a customer's lifetime spend — and each of those would have to be
   * taught the new word separately. That is roughly forty places, and the one
   * that got missed would be a shop's money quietly going somewhere.
   *
   * So a shipped job stays `completed` and carries a `shippedAt`, exactly as a
   * delivered one carries a `deliveredAt`, and `stageOf` reads the pair. The
   * board gets its column, the money stays where it was, and nothing had to be
   * told twice.
   *
   * Only from `completed`, and not once it has arrived: posting a job that is
   * already with the customer is the clock running backwards.
   *
   * This is the shop's own record of the parcel leaving. `order.shippingStatus`
   * is a different thing — what a carrier's tracking says — and a shop with no
   * carrier wired up still needs to be able to say a job went out.
   */
  function markShipped(order, ctx) {
    const c = ctxOfStatus(ctx);
    const nowMs = typeof c.now === 'number' ? c.now : Date.now();
    if (!order || order.status !== 'completed') {
      return { ok: false, block: { code: 'not_completed', params: {} }, effects: [] };
    }
    if (order.deliveredAt) {
      return { ok: false, block: { code: 'already_delivered', params: {} }, effects: [] };
    }
    const nowIso = new Date(nowMs).toISOString();
    order.shippedAt = nowIso;
    pushHistory(order, 'shipped', nowIso);
    return {
      ok: true,
      block: null,
      effects: [
        { type: 'activity_log', text: `${order.id} \u2192 shipped` },
        { type: 'save' },
        { type: 'render', dashboard: true },
        { type: 'toast_shipped' },
      ],
    };
  }

  /**
   * Hand a finished job over.
   *
   * Only from `completed`: a job cannot be delivered before it is made, and
   * `markDelivered` in both apps has always refused otherwise. Returns
   * `{ ok, order, effects }` — `ok` false when the job was not ready, so a
   * caller can say why rather than appear to do nothing.
   *
   * The status does NOT move, and that is the whole rule. See `stageOf`.
   */
  function markDelivered(order, ctx) {
    const c = ctxOfStatus(ctx);
    const nowMs = typeof c.now === 'number' ? c.now : Date.now();
    if (!order || order.status !== 'completed') {
      return { ok: false, block: { code: 'not_completed', params: {} }, effects: [] };
    }
    const nowIso = new Date(nowMs).toISOString();
    order.deliveredAt = nowIso;
    pushHistory(order, 'delivered', nowIso);
    return {
      ok: true,
      block: null,
      effects: [
        { type: 'activity_log', text: `${order.id} → delivered` },
        { type: 'save' },
        { type: 'render', dashboard: true },
        { type: 'toast_delivered' },
      ],
    };
  }

  /**
   * What this move would reach OUTSIDE the shop's own book.
   *
   * `apply()` returns every effect a move asks for; most of them — saving,
   * redrawing, deducting — happen inside the shop. A handful leave it: a
   * webhook to somebody's ERP, a Telegram message, an email to the customer, a
   * refresh of the link they are watching. Those are not undoable and not
   * repeatable, and an app that cannot perform them must not perform the move
   * and quietly skip them.
   *
   * So this answers, before anything is written: which of them would this
   * particular move, in this particular shop, actually reach? A shop with no
   * integrations configured gets an empty list and a move that is complete.
   *
   * `ctx`: `{ settings, clients }`. Returns `[{ channel, why }]`, where
   * `channel` is the message code naming it.
   *
   * THE CONDITIONS ARE THE RENDERER'S OWN, and they have to stay that way. Each
   * one is the guard the corresponding function opens with:
   *
   *   webhooks       renderer/integrations.js       fireWebhook
   *   event_webhook  renderer/operations-extras.js  fireOrderWebhook
   *   telegram       renderer/integrations.js       sendTelegramForOrder
   *   email          renderer/integrations.js       autoSendEmailNotification
   *   portal         renderer/integrations.js       republishPortalIfPublished
   *
   * A guard that changes there and not here turns this from a promise into a
   * guess. `autoExportStatusPage` is deliberately absent: it writes a local
   * file, reaches nobody, and going stale is not the same as being missed.
   */
  function outboundFor(order, newStatus, ctx) {
    const c = ctxOfStatus(ctx);
    const settings = c.settings || {};
    const clients = Array.isArray(c.clients) ? c.clients : [];
    const out = [];

    const webhooks = settings.webhooks || {};
    if (webhooks.enabled) out.push({ channel: 'webhooks', why: 'enabled' });

    const events = settings.eventWebhooks || {};
    if (events.enabled && /^https:\/\//i.test(events.url || '') &&
        !(events.events && events.events.status === false)) {
      out.push({ channel: 'event_webhook', why: 'enabled' });
    }

    // Telegram is per-status: it announces a completion and a hold, and stays
    // quiet for everything else, so moving a job to `printing` reaches nobody.
    const tg = settings.telegram || {};
    if (tg.botToken && tg.chatId &&
        ((newStatus === 'completed' && tg.notifyOnComplete) ||
         (newStatus === 'on_hold' && tg.notifyOnHold))) {
      out.push({ channel: 'telegram', why: newStatus });
    }

    // Email is per-status too, and needs a customer with an address on file.
    //
    // ASKED rather than repeated. These conditions used to be written out here
    // as well as in the renderer, which is the thing the comment above warns
    // about: two copies of a guard, and the promise this function makes is only
    // as good as the day they last agreed. `lib/order-email.js` owns them now
    // and both callers ask it.
    //
    // `via` is the provider, and it is here because it decides whether a host
    // can carry this at all: `sendgrid` and `mailgun` are one HTTPS POST, and
    // `custom` is SMTP, which the Mac app does not speak. A host that cannot
    // carry it must refuse the move — so it has to be able to tell, before the
    // move, which one it is being asked for.
    //
    // MISSING IS LOUD, unlike `KhaytAssembly` above. A build without assembly
    // behaves as it did before assembly existed, which is a smaller app and
    // not a wrong one. A build without this module would answer "this move
    // reaches nobody" for a shop that emails every customer, and the Mac would
    // then make the move it is supposed to refuse. Silence is the failure, so
    // there is none: a host that has not loaded it finds out on the first move.
    const email = emailApi();
    if (!email) throw new Error('order-status: lib/order-email.js is not loaded');
    const mail = email.wouldSend(order, newStatus, { settings, clients });
    if (mail.send) out.push({ channel: 'email', why: newStatus, via: mail.provider });

    // The portal link only refreshes for a job that was actually published.
    //
    // ASKED, like the email above. The conditions used to be written out here
    // AND in the renderer, and they had already drifted: this one never looked
    // at the portal trial, so a shop whose trial had lapsed was told a move
    // would reach the customer's link when `republishPortalIfPublished` would
    // have returned early and sent nothing. On the Mac that is a move refused
    // for a message nobody was going to get.
    //
    // `ctx.now` is passed straight through and is optional — the module's own
    // note explains why a missing clock means "assume the link is live".
    const portal = portalApi();
    if (!portal) throw new Error('order-status: lib/portal-refresh.js is not loaded');
    if (portal.wouldRefresh(order, { settings, now: c.now })) {
      out.push({ channel: 'portal', why: 'published' });
    }

    return out;
  }

  /**
   * Format a survey token from `SURVEY_TOKEN_BYTES` random bytes.
   *
   * The bytes come from the caller because a random source is exactly what a
   * pure module does not have — Node, the renderer and JavaScriptCore each
   * reach for a different one. The *format* is here so both apps mint the same
   * kind of token.
   */
  function makeSurveyToken(bytes) {
    return 'srv-' + Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
  }

  const api = {
    HISTORY_CAP, SURVEY_TOKEN_BYTES, FINISHED_STATUSES, isFinished,
    wouldExceedWipLimit, gate, apply, outboundFor, stageOf, markDelivered, markShipped, stampFromShipping, IN_THE_POST,
    resumeFromHold, makeSurveyToken,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderStatus = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
