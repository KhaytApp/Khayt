'use strict';

(function (global) {
/**
 * What each dashboard layout actually answers, declared rather than discovered.
 *
 * THE PROBLEM THIS EXISTS FOR
 *
 * Khayt's eight themes are eight different screens, deliberately — Flow is a
 * kanban, Meridian a schedule, Foreman a wallboard, Command and Vivid lead with
 * figures, Workbench leads with the work. That is the feature and it stays.
 *
 * What is NOT a feature is that switching theme silently changes what you can
 * see. Average margin appears on two layouts of eight. Revenue on three. A shop
 * that picked Workbench because it liked the look has no way to know it gave up
 * the margin figure, and no way to find out except to install another theme.
 *
 * Worse, a deliberate omission and an accidental one look identical. Workbench
 * dropping the revenue tiles is a considered decision and its source says so at
 * length — where every number went, and that "this is a move and not a
 * deletion". Nothing else in the codebase records that, so the reasoning lives
 * in a comment that no test reads and no user ever sees.
 *
 * WHAT THIS IS AND IS NOT
 *
 * It is a declaration, not a derivation. A theme says what it shows and what it
 * deliberately leaves out, and the test below insists every capability is
 * addressed one way or the other — so a gap has to be an answer rather than a
 * silence. It does not force any theme to show anything.
 *
 * A missing REASON is recorded as null rather than invented. Four of the six
 * custom layouts never wrote down why they omit what they omit, and putting
 * plausible words in their author's mouth would defeat the point of writing it
 * down at all. `unexplainedOmissions()` reports them, and the test surfaces the
 * count without failing — the same shape as the locale orphan report.
 *
 * SEEDED FROM WHAT THE CODE RENDERS, NOT FROM MEMORY
 *
 * Every `shows` entry below was verified against the label the layout actually
 * renders, and `test/theme-capabilities.test.js` re-checks that claim so the
 * manifest cannot quietly start lying.
 */

/**
 * The capabilities a dashboard can answer.
 *
 * Deliberately small and entirely verified. Anything that could not be confirmed
 * from a rendered label was left out rather than guessed at — a registry that
 * is half-true is worse than one that is short.
 */
const CAPABILITIES = {
  revenue: {
    labelKey: 'cap.revenue',
    label: 'Revenue figures',
    detail: 'What the shop took, for a day, week or month.',
  },
  margin: {
    labelKey: 'cap.margin',
    label: 'Average margin',
    detail: 'What is left after costs — the number that says whether the pricing works.',
  },
  receivables: {
    labelKey: 'cap.receivables',
    label: 'Unpaid and outstanding',
    detail: 'Money owed to the shop, and by whom.',
  },
  fleetUtilisation: {
    labelKey: 'cap.fleet_utilisation',
    label: 'Fleet utilisation',
    detail: 'How much of the fleet is actually working.',
  },
};

/** The layout each theme uses. Themes with no `screens.js` render the base one. */
const BASE = 'base';

const THEMES = {
  // ── Layouts with no screens.js: they render renderer/dashboard.js ──────────
  nocturne:  { layout: BASE },
  blueprint: { layout: BASE },
  khayt:     { layout: BASE },

  // ── Custom layouts ────────────────────────────────────────────────────────
  command: {
    shows: ['revenue', 'margin', 'receivables'],
    omits: {
      fleetUtilisation: null,
    },
  },
  vivid: {
    shows: ['revenue', 'fleetUtilisation'],
    omits: {
      margin: null,
      receivables: null,
    },
  },
  workbench: {
    shows: ['receivables'],
    omits: {
      // The only omission in this file written by the person who made it. Quoted
      // rather than paraphrased, because the reasoning is the valuable part.
      revenue: 'Moved to Analytics, which is where revenue and aged receivables '
        + 'already live. The KPI wall "answered questions nobody had walked up to '
        + 'the screen to ask" while the fleet sat below the fold — a move, not a '
        + 'deletion. See renderer/themes/workbench/screens.js.',
      margin: null,
      fleetUtilisation: null,
    },
  },
  foreman: {
    shows: ['receivables'],
    omits: {
      revenue: null,
      margin: null,
      fleetUtilisation: null,
    },
  },
  flow: {
    shows: ['receivables'],
    omits: {
      revenue: null,
      margin: null,
      fleetUtilisation: null,
    },
  },
  meridian: {
    shows: [],
    omits: {
      revenue: null,
      margin: null,
      receivables: null,
      fleetUtilisation: null,
    },
  },
};

/** The base layout's own capabilities — what a theme with no screens.js gets. */
const BASE_LAYOUT = { shows: ['revenue', 'margin', 'receivables', 'fleetUtilisation'], omits: {} };

/** Resolve a theme to its declaration, following `layout: 'base'`. */
function manifestFor(themeId) {
  const t = THEMES[themeId];
  if (!t) return null;
  if (t.layout === BASE) return { ...BASE_LAYOUT, layout: BASE };
  return { shows: t.shows || [], omits: t.omits || {}, layout: themeId };
}

/** Does this theme's dashboard answer this question? */
function shows(themeId, capability) {
  const m = manifestFor(themeId);
  return !!(m && m.shows.includes(capability));
}

/**
 * What changes if a shop switches from one theme to another.
 *
 * This is the user-facing point of the whole file: the theme picker can say
 * "Workbench does not show average margin" BEFORE the switch rather than leaving
 * someone to notice its absence weeks later, or never.
 *
 * @returns {{gained: string[], lost: string[]}} capability ids
 */
function differenceBetween(fromTheme, toTheme) {
  const a = manifestFor(fromTheme);
  const b = manifestFor(toTheme);
  if (!a || !b) return { gained: [], lost: [] };
  return {
    gained: b.shows.filter((c) => !a.shows.includes(c)),
    lost: a.shows.filter((c) => !b.shows.includes(c)),
  };
}

/** Omissions with no recorded reason — reported, never invented. */
function unexplainedOmissions() {
  const out = [];
  for (const [id, t] of Object.entries(THEMES)) {
    if (t.layout === BASE) continue;
    for (const [cap, reason] of Object.entries(t.omits || {})) {
      if (reason == null) out.push({ theme: id, capability: cap });
    }
  }
  return out;
}

const api = { CAPABILITIES, THEMES, BASE_LAYOUT, manifestFor, shows, differenceBetween, unexplainedOmissions };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytThemeCapabilities = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
