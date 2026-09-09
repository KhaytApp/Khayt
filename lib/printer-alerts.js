/**
 * Pure printer fleet alerting logic (renderer + node:test).
 *
 * `computePrinterAlerts(prevState, currState, settings, now)` diffs the previous
 * and current printer-status caches and returns the alerts that should fire on
 * this poll, honouring per-machine cooldowns and the user's notification toggles.
 *
 * It is deliberately side-effect free: it never sends anything and never mutates
 * its inputs. The caller persists the returned `state` (cooldown/stall bookkeeping)
 * and is responsible for actually dispatching each alert through the existing
 * Telegram/email/webhook transports.
 *
 * Shapes
 *   statusCache: { [machineId]: {
 *     state, progress, filename, timeRemaining, tempNozzle, tempBed, error, lastUpdated
 *   } }   // exactly what main.js's printerStatusCache holds
 *
 *   alertState (opaque, owned by this module): {
 *     [machineId]: {
 *       failCount,          // consecutive failed polls (for offline threshold)
 *       lastProgress,       // progress value last seen while printing
 *       lastProgressAt,     // ms timestamp progress last advanced
 *       cooldowns: { error, offline, stall, runout }  // ms timestamp each type last fired
 *     }
 *   }
 *
 * Returns: { alerts: [{ machineId, type, message, state, filename, progress }], state }
 */
(function (global) {
  'use strict';

  const DEFAULTS = {
    offlineThreshold: 3, // consecutive failed polls before "offline"
    stallMinutes: 15, // minutes without progress while printing before "stall"
    cooldownMinutes: 30, // per-machine, per-type minimum gap between alerts
  };

  const MINUTE = 60 * 1000;

  function isPrinting(state) {
    return /print/i.test(String(state || ''));
  }

  function isErrorState(s) {
    if (!s) return false;
    if (s.error) return true;
    return /error|fault|halt|attention/i.test(String(s.state || ''));
  }

  // A poll "failed" when main.js stored an { error } object (host unreachable etc.).
  function isFailedPoll(s) {
    return !!(s && s.error);
  }

  function num(v, fallback = 0) {
    const n = Number(v);
    return Number.isFinite(n) ? n : fallback;
  }

  function cloneMachineState(m) {
    return {
      failCount: num(m && m.failCount, 0),
      lastProgress: m && typeof m.lastProgress === 'number' ? m.lastProgress : null,
      lastProgressAt: m && typeof m.lastProgressAt === 'number' ? m.lastProgressAt : null,
      cooldowns: {
        error: num(m && m.cooldowns && m.cooldowns.error, 0),
        offline: num(m && m.cooldowns && m.cooldowns.offline, 0),
        stall: num(m && m.cooldowns && m.cooldowns.stall, 0),
        runout: num(m && m.cooldowns && m.cooldowns.runout, 0),
      },
    };
  }

  function resolveSettings(settings, enable) {
    const tg = (settings && settings.telegram) || {};
    // Only default the toggles ON when Telegram is actually configured. With no settings
    // at all there is nothing to notify through, and "no settings → no alerts" is a
    // property the tests pin deliberately.
    const configured = !!(settings && settings.telegram);
    return {
      // Default ON, matching what the settings UI renders (`tg.notifyPrinterError ?? true`).
      // The old ternary was a no-op — both branches reduced to !!tg.notifyPrinterX — so an
      // install that configured Telegram BEFORE these keys existed showed a ticked box and
      // never sent a single printer alert. settings.js only seeds the keys when
      // settings.telegram is entirely absent, so upgraded installs kept an object without
      // them.
      // `enable` OVERRIDES the three above, and exists because the toggles are
      // Telegram's. `configured` gates every alert on Telegram being set up,
      // which is right when Telegram is the transport and wrong when it is not:
      // the Mac app raises a notification on the machine the shop is sitting
      // at, and a shop with no bot would otherwise have been told nothing at
      // all. Absent, this is exactly the behaviour it has always had.
      notifyError: enable ? !!enable.error : (configured && tg.notifyPrinterError !== false),
      notifyOffline: enable ? !!enable.offline : (configured && tg.notifyPrinterOffline !== false),
      notifyStall: enable ? !!enable.stall : !!tg.notifyPrinterStall,
      // Defaults ON with the others, unlike stall. A runout is not a judgement
      // call the way "stuck at 47%" is — the machine said so itself, and a
      // shop that is not told simply loses the hours until somebody walks past.
      notifyRunout: enable ? !!enable.runout : (configured && tg.notifyPrinterRunout !== false),
      offlineThreshold: clampInt(
        (settings && settings.printerAlerts && settings.printerAlerts.offlineThreshold),
        DEFAULTS.offlineThreshold,
        1,
        50,
      ),
      stallMinutes: clampInt(
        (settings && settings.printerAlerts && settings.printerAlerts.stallMinutes),
        DEFAULTS.stallMinutes,
        1,
        24 * 60,
      ),
      cooldownMinutes: clampInt(
        (settings && settings.printerAlerts && settings.printerAlerts.cooldownMinutes),
        DEFAULTS.cooldownMinutes,
        0,
        24 * 60,
      ),
    };
  }

  function clampInt(v, fallback, min, max) {
    const n = Math.round(Number(v));
    if (!Number.isFinite(n)) return fallback;
    return Math.min(max, Math.max(min, n));
  }

  function nameFor(machineId, machines) {
    if (Array.isArray(machines)) {
      const m = machines.find((x) => x && x.id === machineId);
      if (m && m.name) return m.name;
    }
    return machineId;
  }

  /**
   * @param {object} prevState  previous status cache (snapshot from the last poll)
   * @param {object} currState  current status cache (this poll)
   * @param {object} settings   renderer settings object (reads settings.telegram.*, settings.printerAlerts.*)
   * @param {number} now        ms timestamp (Date.now())
   * @param {object} [opts]     { alertState, machines, enable }
   *   `enable: { error, offline, stall }` replaces the Telegram toggles for a
   *   caller whose transport is not Telegram.
   */
  function computePrinterAlerts(prevState, currState, settings, now, opts) {
    const ts = Number.isFinite(now) ? now : Date.now();
    const options = opts || {};
    const machines = options.machines;
    const cfg = resolveSettings(settings, options.enable);
    const prev = prevState || {};
    const curr = currState || {};
    const inState = options.alertState || {};
    const outState = {};
    const alerts = [];

    for (const machineId of Object.keys(curr)) {
      const s = curr[machineId] || {};
      const p = prev[machineId] || {};
      const ms = cloneMachineState(inState[machineId]);
      const machineName = nameFor(machineId, machines);

      const cooldownMs = cfg.cooldownMinutes * MINUTE;
      const offCooldown = (type) => ts - ms.cooldowns[type] >= cooldownMs;

      // --- offline: N consecutive failed polls ---
      if (isFailedPoll(s)) {
        ms.failCount += 1;
      } else {
        ms.failCount = 0;
      }
      // crossing the threshold (== so it fires once at the edge; cooldown gates repeats)
      if (cfg.notifyOffline && ms.failCount >= cfg.offlineThreshold && offCooldown('offline')) {
        alerts.push({
          machineId,
          type: 'offline',
          message: `Printer offline: ${machineName} (${ms.failCount} failed checks)`,
          state: 'offline',
          filename: '',
          progress: 0,
        });
        ms.cooldowns.offline = ts;
      }

      // --- error: transition INTO an error state ---
      // Treat a failed poll as "offline", not "error", so we don't double-fire.
      const currErr = !isFailedPoll(s) && isErrorState(s);
      const prevErr = !isFailedPoll(p) && isErrorState(p);
      if (cfg.notifyError && currErr && !prevErr && offCooldown('error')) {
        const detail = s.error || s.state || 'error';
        alerts.push({
          machineId,
          type: 'error',
          message: `Printer error: ${machineName} — ${detail}`,
          state: String(s.state || 'error'),
          filename: s.filename || '',
          progress: num(s.progress, 0),
        });
        ms.cooldowns.error = ts;
      }

      // --- runout: the printing head has no filament ---
      //
      // BEFORE the stall check, and deliberately: a print stopped for want of
      // filament stops advancing, so the stall clock would eventually fire and
      // say "stuck at 47%" — true, useless, and the wrong errand. "Load a
      // spool" and "something is wrong" send a shop to the machine with
      // different tools in hand.
      //
      // `filamentOut` is three-way. Only `true` is news: `false` is a loaded
      // machine and `null` is one with no sensor, and neither is a reason to
      // walk across a workshop. On a toolchanger it is already the LIVE head's
      // sensor — a spare head sitting empty is an empty slot, not a runout.
      const outNow = s.filamentOut === true;
      const outBefore = p && p.filamentOut === true;
      if (cfg.notifyRunout && outNow && !outBefore && offCooldown('runout')) {
        alerts.push({
          machineId,
          type: 'runout',
          message: `Out of filament: ${machineName}`,
          state: String(s.state || 'printing'),
          filename: s.filename || '',
          progress: num(s.progress, 0),
        });
        ms.cooldowns.runout = ts;
      }

      // --- stall: progress not advancing while printing ---
      //
      // NOT while the machine is out of filament. A runout stops progress, so
      // the stall clock reaches its threshold and the shop is told twice about
      // one thing — once correctly ("out of filament") and once uselessly
      // ("stuck at 47% for 60 min"). The stall rule is for a print that has
      // stopped for a reason nobody knows; this one has a reason, and it is
      // already on the screen. The clock still RUNS, so a machine that is
      // refilled and still not moving stalls on schedule.
      if (!isFailedPoll(s) && isPrinting(s.state)) {
        const progress = num(s.progress, 0);
        if (ms.lastProgressAt === null || ms.lastProgress === null || progress > ms.lastProgress) {
          // progress advanced (or first sighting) → reset the stall clock
          ms.lastProgress = progress;
          ms.lastProgressAt = ts;
        } else {
          const stalledFor = ts - ms.lastProgressAt;
          if (
            cfg.notifyStall &&
            s.filamentOut !== true &&
            stalledFor >= cfg.stallMinutes * MINUTE &&
            offCooldown('stall')
          ) {
            const mins = Math.round(stalledFor / MINUTE);
            alerts.push({
              machineId,
              type: 'stall',
              message: `Print stalled: ${machineName} stuck at ${Math.round(progress)}% for ${mins} min`,
              state: String(s.state || 'printing'),
              filename: s.filename || '',
              progress,
            });
            ms.cooldowns.stall = ts;
          }
        }
      } else {
        // not printing → no stall tracking
        ms.lastProgress = null;
        ms.lastProgressAt = null;
      }

      outState[machineId] = ms;
    }

    // carry forward state for machines that vanished this poll (defensive)
    for (const machineId of Object.keys(inState)) {
      if (!outState[machineId]) outState[machineId] = cloneMachineState(inState[machineId]);
    }

    return { alerts, state: outState };
  }

  const api = {
    computePrinterAlerts,
    isPrinting,
    isErrorState,
    isFailedPoll,
    DEFAULTS,
  };

  global.KhaytPrinterAlerts = api;
  global.computePrinterAlerts = computePrinterAlerts;

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
