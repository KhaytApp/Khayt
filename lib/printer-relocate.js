'use strict';
/**
 * A printer that changed address is not a printer that went away.
 *
 * Machines are configured by IP. A DHCP lease expires overnight, the router
 * hands out a different address, and from then on Khayt polls a host that
 * answers nothing. The app is not wrong about anything it says — the machine
 * genuinely is unreachable — but the owner is shown "offline", which is the same
 * thing it says when a printer is switched off, and the two have completely
 * different fixes.
 *
 * The cost is worse than a wrong badge, because some of what polling does cannot
 * be caught up on later. `captureCompletion` freezes a job's real filament and
 * duration on the edge out of printing, and the counters reset when the next job
 * starts — so every print that finishes while the address is stale is a
 * measurement that no longer exists. Found exactly that way, on the bench:
 * a Snapmaker U1 moved from .77 to .56, and the shop's completion history was
 * empty rather than short.
 *
 * Nothing here needed inventing. lib/printer-discovery.js already browses the
 * LAN, already prefers the TXT-advertised `ip=` over a stale A record, and
 * already extracts the serial number — which is the one thing about a printer
 * that a DHCP lease cannot change. It was only ever wired to ADD a printer,
 * never to repair one.
 *
 * Pure: takes machines and whatever discovery found, returns what to do about
 * it. The socket work stays in main.js, as it does for discovery itself.
 */
(function () {
  let pollCache = null;
  try { pollCache = require('./printer-poll-cache.js'); } catch { /* renderer supplies it */ }

  /**
   * How confident we are that a discovered printer IS a given configured machine.
   *
   *   mac    — the hardware address we recorded for this machine while it was
   *            working. Strongest of the three and the only one that works for
   *            every protocol: probed live, Moonraker offers a board serial and
   *            OctoPrint, PrusaLink and Duet offer nothing durable at all. An
   *            address is handed to an interface; the interface does not change
   *            with the lease.
   *   serial — the printer announced the serial we recorded for this machine.
   *            That is identity, not resemblance, so it is safe to apply without
   *            asking. A serial does not move with a lease.
   *   model  — no serial to go on, but exactly one printer on the LAN speaks the
   *            right protocol AND advertises the right model AND is not already
   *            some other machine's address. Strong, and still a guess: PROPOSE
   *            it, never apply it. Retargeting is a write, and the write points
   *            the app at a machine it will later send commands to.
   *   protocol — weakest, and only ever from a SWEEP. Nothing announced itself;
   *            we asked this subnet directly and exactly one address answered in
   *            this machine's protocol. Proposed with the doubt stated, because
   *            the alternative is what the U1 got: a correct diagnosis discarded
   *            for being uncertain, and an owner left on "offline".
   */
  const CONFIDENCE = { MAC: 'mac', SERIAL: 'serial', MODEL: 'model', PROTOCOL: 'protocol' };

  /** Why no move was proposed. Distinct reasons, because they need distinct advice. */
  const NO_MOVE = {
    SAME_HOST: 'same-host',     // found it, already configured correctly
    AMBIGUOUS: 'ambiguous',     // several candidates, none provable
    NOT_FOUND: 'not-found',     // nothing on the LAN looks like this machine
  };

  /** Lower-case colon form, zero-padded, so two spellings of one MAC compare equal. */
  function normalizeMac(value) {
    const m = /\b([0-9a-f]{1,2}(?:[:-][0-9a-f]{1,2}){5})\b/i.exec(String(value || ''));
    if (!m) return '';
    const joined = m[1].split(/[:-]/).map((x) => x.toLowerCase().padStart(2, '0')).join(':');
    return (joined === '00:00:00:00:00:00' || joined === 'ff:ff:ff:ff:ff:ff') ? '' : joined;
  }

  /** Strip scheme, trailing slash and any :port so two spellings of one host compare equal. */
  function bareHost(value) {
    return String(value || '')
      .trim()
      .replace(/^https?:\/\//i, '')
      .replace(/\/+$/, '')
      .replace(/:\d+$/, '')
      .toLowerCase();
  }

  /** Serials are printed on labels and retyped by people; compare them forgivingly. */
  function sameSerial(a, b) {
    const norm = (s) => String(s || '').replace(/[^a-z0-9]+/gi, '').toLowerCase();
    const x = norm(a);
    return !!x && x === norm(b);
  }

  function norm(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ''); }

  /** Is this machine one Khayt actually talks to over the network? */
  function isControllable(machine) {
    const type = String((machine && machine.printerApi && machine.printerApi.type) || '').toLowerCase();
    return !!type && type !== 'none';
  }

  /**
   * Does a discovered printer describe the same model as a configured machine?
   *
   * Compared against every name the machine record carries, because they are
   * populated from different places — the catalog match, the advertised model,
   * and whatever the owner typed. The catalog id is the strongest of them: it is
   * the same identifier on both sides when discovery matched the catalog.
   */
  function modelMatches(machine, found) {
    const m = machine || {};
    const f = found || {};
    if (m.catalogId && f.catalogId && m.catalogId === f.catalogId) return true;
    const mine = [m.printerModel, m.printerModelName, m.vendor && m.name, m.name]
      .map(norm).filter(Boolean);
    const theirs = [f.model, f.name, f.vendor && f.model].map(norm).filter(Boolean);
    if (!mine.length || !theirs.length) return false;
    return theirs.some((t) => mine.some((x) => x === t || x.includes(t) || t.includes(x)));
  }

  /**
   * Has this machine missed enough polls that "it moved" is worth considering?
   *
   * A single missed poll is a blip — Wi-Fi, a busy printer, a slow answer — and
   * rescanning the LAN on every blip would put a multicast burst on the network
   * every thirty seconds for a machine that is fine.
   */
  function looksOffline(entry, threshold) {
    if (pollCache && typeof pollCache.isOffline === 'function') {
      return pollCache.isOffline(entry, threshold);
    }
    if (!entry || !entry.error) return false;
    return (entry.consecutiveFailures || 0) >= threshold;
  }

  /**
   * What to do about each machine that cannot be reached.
   *
   * @param {object}   opts
   * @param {object[]} opts.machines          the shop's machines
   * @param {object[]} opts.discovered        lib/printer-discovery.js output
   * @param {object}   [opts.statusCache]     machineId → poll-cache entry
   * @param {number}   [opts.offlineThreshold=2]
   * @param {boolean}  [opts.requireOffline=true]  false when the owner asked directly
   * @returns {{moves: object[], noMoves: object[]}}
   */
  function planRelocations(opts) {
    const o = opts || {};
    const machines = Array.isArray(o.machines) ? o.machines : [];
    const discovered = Array.isArray(o.discovered) ? o.discovered : [];
    const statusCache = o.statusCache || {};
    const threshold = Number.isFinite(o.offlineThreshold) ? o.offlineThreshold : 2;
    const requireOffline = o.requireOffline !== false;

    // Addresses already spoken for. Moving a machine onto one of these would
    // quietly make two machine records the same printer, and the shop would
    // send one printer both queues.
    const claimed = new Map();
    for (const m of machines) {
      if (!isControllable(m)) continue;
      claimed.set(bareHost(m.printerApi.host), m.id);
    }

    const moves = [];
    const noMoves = [];

    for (const machine of machines) {
      if (!isControllable(machine)) continue;
      if (requireOffline && !looksOffline(statusCache[machine.id], threshold)) continue;

      const type = String(machine.printerApi.type).toLowerCase();
      const here = bareHost(machine.printerApi.host);
      const sameType = discovered.filter((d) => String(d.connection || '').toLowerCase() === type);

      const note = (reason, extra) => noMoves.push({
        machineId: machine.id, machineName: machine.name || '', reason, ...(extra || {}),
      });

      // Hardware address first, because it is the only identity that exists for
      // every protocol. Recorded while the machine was reachable, so a match here
      // is the same printer on a different lease — not a resemblance.
      const storedMac = normalizeMac(machine.printerApi.mac);
      if (storedMac) {
        const hit = sameType.find((d) => normalizeMac(d.mac) === storedMac);
        if (hit) {
          if (bareHost(hit.host) === here) { note(NO_MOVE.SAME_HOST, { host: hit.host }); continue; }
          moves.push(describeMove(machine, hit, CONFIDENCE.MAC,
            'the printer at this address has the hardware address recorded for this machine'));
          continue;
        }
        // Fall through rather than giving up: the neighbour table only knows
        // hosts this computer has spoken to recently, so a missing MAC means
        // "not asked yet", never "not this printer".
      }

      // Identity next. A serial match settles it even when the machine is one of
      // five identical printers on the bench.
      const stored = machine.printerApi.serial;
      if (stored) {
        const hit = sameType.find((d) => sameSerial(d.serial, stored));
        if (hit) {
          if (bareHost(hit.host) === here) { note(NO_MOVE.SAME_HOST, { host: hit.host }); continue; }
          moves.push(describeMove(machine, hit, CONFIDENCE.SERIAL,
            'the printer announced the serial recorded for this machine'));
          continue;
        }
        note(NO_MOVE.NOT_FOUND, { serial: stored });
        continue;
      }

      // No identity recorded — so this machine predates the serial being kept, or
      // was added by hand. Fall back to "there is exactly one printer this could
      // be", and refuse as soon as that stops being true.
      const free = sameType.filter((d) => {
        const owner = claimed.get(bareHost(d.host));
        return !owner || owner === machine.id;
      });
      if (!free.length) { note(NO_MOVE.NOT_FOUND); continue; }

      const byModel = free.filter((d) => modelMatches(machine, d));
      const pool = byModel.length ? byModel : free;
      if (pool.length !== 1) {
        note(NO_MOVE.AMBIGUOUS, { candidates: pool.map((d) => ({ host: d.host, name: d.name, serial: d.serial })) });
        continue;
      }
      const only = pool[0];
      if (bareHost(only.host) === here) { note(NO_MOVE.SAME_HOST, { host: only.host }); continue; }
      if (!byModel.length) {
        // One candidate, and nothing agreed about what it IS. Thin evidence —
        // but where it came from decides whether it is worth showing.
        //
        // An mDNS candidate that advertised no model told us nothing we asked
        // for, and stays a noMove as it always has.
        //
        // A SWEPT candidate is different in kind. Nothing announced it; we went
        // to that address, spoke this machine's protocol at this machine's port,
        // and something answered in that protocol's own shape. It is still not
        // proof of WHICH printer — so it is proposed, never applied — but
        // refusing to mention it is how the U1 case stayed invisible: the whole
        // point of sweeping is defeated if the one thing found is then swallowed
        // as "ambiguous" and rendered nowhere.
        if (only.via !== 'sweep') {
          note(NO_MOVE.AMBIGUOUS, { candidates: [{ host: only.host, name: only.name, serial: only.serial }] });
          continue;
        }
        moves.push(describeMove(machine, only, CONFIDENCE.PROTOCOL,
          'the only device on this subnet answering this machine\'s protocol — check it is the right printer'));
        continue;
      }
      moves.push(describeMove(machine, only, CONFIDENCE.MODEL,
        'the only printer on the network speaking this protocol and advertising this model'));
    }

    return { moves, noMoves };
  }

  function describeMove(machine, found, confidence, why) {
    const port = Number(found.port) || 0;
    const current = Number(machine.printerApi.port) || 0;
    return {
      machineId: machine.id,
      machineName: machine.name || '',
      from: machine.printerApi.host || '',
      to: found.host,
      // Only offered when it actually differs, so applying a move never silently
      // overrides a port the owner chose for a reason.
      port: port && port !== current ? port : null,
      serial: found.serial || '',
      firmware: found.firmware || '',
      confidence,
      why,
    };
  }

  /**
   * The machine record a move produces. Pure — the caller persists it.
   *
   * The serial is recorded on the way through, so a machine that had to be
   * matched on model this time is matched on identity next time.
   */
  function applyRelocation(machine, move) {
    if (!machine || !move || machine.id !== move.machineId) return machine;
    const api = { ...(machine.printerApi || {}) };
    api.host = move.to;
    if (move.port) api.port = move.port;
    if (move.serial) api.serial = move.serial;
    return { ...machine, printerApi: api };
  }

  /**
   * Serials worth recording for machines that are reachable right now.
   *
   * This is what makes the feature work for printers added before it existed.
   * A machine only gets a provable identity while it is still answering at the
   * address it is configured with — so the moment to learn one is any successful
   * scan, not the moment it goes missing. By then the address is stale and the
   * strongest available match has already dropped to a guess.
   *
   * @returns {Array<{machineId: string, serial: string}>}
   */
  function learnSerials(opts) {
    const o = opts || {};
    const machines = Array.isArray(o.machines) ? o.machines : [];
    const discovered = Array.isArray(o.discovered) ? o.discovered : [];
    const out = [];
    for (const machine of machines) {
      if (!isControllable(machine)) continue;
      if (machine.printerApi.serial) continue;          // already known
      const type = String(machine.printerApi.type).toLowerCase();
      const here = bareHost(machine.printerApi.host);
      if (!here) continue;
      const hits = discovered.filter(
        (d) => String(d.connection || '').toLowerCase() === type && bareHost(d.host) === here && d.serial,
      );
      // Two printers answering for one address is not something to resolve by
      // picking one; it means something is wrong with the network, not with this.
      if (hits.length === 1) out.push({ machineId: machine.id, serial: hits[0].serial });
    }
    return out;
  }

  /**
   * Is a LAN scan worth running right now?
   *
   * The original failure was SILENT: nobody scans a printer they have no reason
   * to think has moved, so leaving this behind a button meant the one owner who
   * needed it was the one who would never press it. The diagnosis has to happen
   * on its own — which makes "how often" a real question, because a scan is a
   * multicast burst and the poll loop runs every thirty seconds.
   *
   * So: only when something is actually offline and not already explained, and
   * never more than once per `minIntervalMs` however many machines are down.
   *
   * A printer that is genuinely switched off is never explained, so it keeps
   * qualifying — deliberately. That costs one short scan every ten minutes and
   * buys the case that matters: a machine that was off, came back, and came back
   * on a different address than the one it left on.
   */
  function shouldScan(opts) {
    const o = opts || {};
    const machines = Array.isArray(o.machines) ? o.machines : [];
    const statusCache = o.statusCache || {};
    const now = Number.isFinite(o.now) ? o.now : Date.now();
    const minIntervalMs = Number.isFinite(o.minIntervalMs) ? o.minIntervalMs : 10 * 60 * 1000;
    const threshold = Number.isFinite(o.offlineThreshold) ? o.offlineThreshold : 2;
    if (now - (Number(o.lastScanAt) || 0) < minIntervalMs) return false;
    return machines.some((m) => {
      if (!isControllable(m)) return false;
      const entry = statusCache[m.id];
      return looksOffline(entry, threshold) && !(entry && entry.relocated);
    });
  }

  /**
   * What to tell the owner instead of a raw errno, when we know.
   *
   * `connect ETIMEDOUT 192.168.68.77:7125` is true and useless: it describes the
   * symptom in the vocabulary of a socket. "Found it at 192.168.68.56 — the
   * address changed" is the same fact in the vocabulary of the person who has to
   * do something about it.
   *
   * Returns null when nothing better than the error is known, so every caller
   * can fall back to what it already showed.
   */
  function relocationHint(entry) {
    const r = entry && entry.relocated;
    if (!r || !r.to) return null;
    return { from: r.from || '', to: r.to, confidence: r.confidence || '', serial: r.serial || '' };
  }

  const api = {
    planRelocations, applyRelocation, learnSerials, shouldScan, relocationHint,
    bareHost, sameSerial, modelMatches, isControllable,
    CONFIDENCE, NO_MOVE,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPrinterRelocate = api;
})();
