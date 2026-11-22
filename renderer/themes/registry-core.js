/**
 * Theme registry — pure definitions and helpers (browser + Node testable).
 */
(function (global) {






  /* The 2026 identity's accents. Brand is #216dca, the website's own blue.
     Amber is deliberately absent: in this design it is the thread (progress,
     the active screen), and an amber accent would make every button look like
     a progress mark. */
  const KHAYT_ACCENTS = {
    brand: { h: 213, s: '72%', l: '46%', labelKey: 'theme.accent.khayt_brand' },
    navy:  { h: 213, s: '78%', l: '25%', labelKey: 'theme.accent.khayt_navy' },
    teal:  { h: 174, s: '82%', l: '30%', labelKey: 'theme.accent.khayt_teal' },
  };

  // The theme a fresh install gets, and where a stale or deleted id lands.
  const DEFAULT_DESIGN = 'khayt';

  const WORKBENCH_ACCENTS = {
    indigo:  { h: 236, s: '86%', l: '63%', labelKey: 'theme.accent.indigo' },
    blue:    { h: 220, s: '100%', l: '59%', labelKey: 'theme.accent.workbench_blue' },
    grape:   { h: 264, s: '72%', l: '60%', labelKey: 'theme.accent.grape' },
    emerald: { h: 152, s: '74%', l: '37%', labelKey: 'theme.accent.emerald' },
  };

  const VIVID_ACCENTS = {
    indigo: { h: 244, s: '84%', l: '65%', labelKey: 'theme.accent.vivid_indigo' },
    violet: { h: 271, s: '91%', l: '65%', labelKey: 'theme.accent.vivid_violet' },
    pink:   { h: 330, s: '81%', l: '60%', labelKey: 'theme.accent.vivid_pink' },
    cyan:   { h: 189, s: '94%', l: '43%', labelKey: 'theme.accent.vivid_cyan' },
  };

  const COMMAND_ACCENTS = {
    blue:    { h: 212, s: '73%',  l: '53%', labelKey: 'theme.accent.command_blue' },
    teal:    { h: 168, s: '78%',  l: '37%', labelKey: 'theme.accent.command_teal' },
    violet:  { h: 255, s: '100%', l: '68%', labelKey: 'theme.accent.violet' },
    orange:  { h: 24,  s: '76%',  l: '53%', labelKey: 'theme.accent.command_orange' },
  };

  /* Blueprint reads as drawn linework, so its accents are the pigments a
     drafting set actually carries. Lightnesses are chosen for the warm paper
     ground; the dark variant lifts --accent-l to 66% in tokens.css so the same
     hue still reads on the blue. */
  const BLUEPRINT_ACCENTS = {
    blueprint: { h: 209, s: '69%', l: '35%', labelKey: 'theme.accent.blueprint' },
    graphite:  { h: 205, s: '14%', l: '32%', labelKey: 'theme.accent.graphite' },
    sienna:    { h: 18,  s: '58%', l: '42%', labelKey: 'theme.accent.sienna' },
    verdigris: { h: 174, s: '48%', l: '31%', labelKey: 'theme.accent.verdigris' },
  };

  /* Nocturne's accents are all long-wavelength but one. Amber and ember
     preserve dark adaptation the way an instrument panel does; ice is there
     for people who simply dislike warm UI, and is the only cool option on
     purpose rather than by omission. */
  const NOCTURNE_ACCENTS = {
    amber: { h: 38,  s: '92%', l: '58%', labelKey: 'theme.accent.amber' },
    ember: { h: 16,  s: '88%', l: '58%', labelKey: 'theme.accent.ember' },
    lime:  { h: 74,  s: '68%', l: '52%', labelKey: 'theme.accent.lime' },
    ice:   { h: 196, s: '82%', l: '60%', labelKey: 'theme.accent.ice' },
  };

  /* Meridian's accents are restrained on purpose: the schedule spends its
     colour on JOB STATE, so the accent is really only the now-line and the
     clock. A loud accent here would compete with the blocks that carry data. */
  const MERIDIAN_ACCENTS = {
    signal:  { h: 184, s: '72%', l: '36%', labelKey: 'theme.accent.signal' },
    cobalt:  { h: 218, s: '68%', l: '44%', labelKey: 'theme.accent.cobalt' },
    magenta: { h: 322, s: '60%', l: '46%', labelKey: 'theme.accent.magenta' },
    olive:   { h: 84,  s: '42%', l: '34%', labelKey: 'theme.accent.olive' },
  };

  /* Foreman spends colour on SEVERITY, so its accent only ever marks which row
     has focus. The alternatives stay low-chroma for the same reason. */
  const FOREMAN_ACCENTS = {
    pine:   { h: 158, s: '46%', l: '34%', labelKey: 'theme.accent.pine' },
    slate:  { h: 212, s: '24%', l: '38%', labelKey: 'theme.accent.slate' },
    clay:   { h: 14,  s: '44%', l: '42%', labelKey: 'theme.accent.clay' },
    indigo2:{ h: 244, s: '34%', l: '46%', labelKey: 'theme.accent.muted_indigo' },
  };

  const FLOW_ACCENTS = {
    tide:   { h: 199, s: '60%', l: '48%', labelKey: 'theme.accent.tide' },
    iris:   { h: 258, s: '46%', l: '56%', labelKey: 'theme.accent.iris' },
    moss:   { h: 158, s: '44%', l: '40%', labelKey: 'theme.accent.moss' },
    amber2: { h: 38,  s: '72%', l: '50%', labelKey: 'theme.accent.warm_amber' },
  };

  /** Shells a community theme may declare in its manifest. */
  const CUSTOM_THEME_SHELLS = ['workbench', 'command', 'vivid', 'meridian', 'foreman', 'flow', 'default'];

  /** Reserved Frontier concepts — Pulse and Stream (vNext). */
  const RESERVED_THEMES = {
    pulse: {
      labelKey: 'theme.design.pulse',
      descKey: 'theme.design.pulse_desc',
      shell: 'pulse',
      enabled: false,
      comingSoon: true,
      defaultAccent: 'ember',
      accents: { ember: { h: 12, s: '100%', l: '60%', labelKey: 'theme.accent.ember' } },
      defaultAppearance: 'dark',
      bodyClass: 'khayt-pulse',
      stylesheets: [],
    },
    stream: {
      labelKey: 'theme.design.stream',
      descKey: 'theme.design.stream_desc',
      shell: 'stream',
      enabled: false,
      comingSoon: true,
      defaultAccent: 'iris',
      accents: { iris: { h: 252, s: '100%', l: '74%', labelKey: 'theme.accent.iris' } },
      defaultAppearance: 'dark',
      bodyClass: 'khayt-stream',
      stylesheets: [],
    },
  };

  const BUILTIN_THEMES = {
    /* Khayt — the 2026 identity shared with khaytapp.com and the Mac app:
       navy chrome, white work surface, amber as the thread, deep-navy dark
       mode. Hosted on the Workbench shell like Blueprint, so the layout is
       inherited and only the identity layer (themes/khayt/) is new. */
    khayt: {
      labelKey: 'theme.design.khayt',
      descKey: 'theme.design.khayt_desc',
      preview: 'themes/previews/khayt.png',
      shell: 'workbench',
      enabled: true,
      defaultAccent: 'brand',
      accents: KHAYT_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-2026',
      stylesheets: [
        'themes/khayt/tokens.css',
        'themes/khayt/shell.css',
      ],
    },
    workbench: {
      labelKey: 'theme.design.workbench',
      descKey: 'theme.design.workbench_desc',
      preview: 'themes/previews/workbench.png',
      shell: 'workbench',
      enabled: true,
      defaultAccent: 'indigo',
      accents: WORKBENCH_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-workbench',
      stylesheets: [
        'themes/workbench/tokens.css',
        'themes/workbench/shell.css',
      ],
    },
    vivid: {
      labelKey: 'theme.design.vivid',
      descKey: 'theme.design.vivid_desc',
      preview: 'themes/previews/vivid.png',
      shell: 'vivid',
      enabled: true,
      defaultAccent: 'indigo',
      accents: VIVID_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-vivid',
      stylesheets: [
        'themes/vivid/tokens.css',
        'themes/vivid/shell.css',
        'themes/vivid/screens.css',
      ],
    },
    command: {
      labelKey: 'theme.design.command',
      descKey: 'theme.design.command_desc',
      preview: 'themes/previews/command.png',
      shell: 'command',
      enabled: true,
      defaultAccent: 'blue',
      accents: COMMAND_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-command',
      stylesheets: [
        'themes/command/tokens.css',
        'themes/command/shell.css',
      ],
    },
    /* Khayt's reading of the Bed Ready design language: warm paper, ink type,
       and a blueprint-blue accent used as a drawn line. Hosted on the Workbench
       shell because Bed Ready is a sidebar app; bodyClass adds khayt-blueprint
       ALONGSIDE khayt-workbench (see applyBodyClasses), so the layout is
       inherited and only the identity layer is new. Bed Ready itself is
       untouched — it styles from html[data-app="bedready"] and never reads
       these files. */
    blueprint: {
      labelKey: 'theme.design.blueprint',
      descKey: 'theme.design.blueprint_desc',
      preview: 'themes/previews/blueprint.png',
      shell: 'workbench',
      enabled: true,
      defaultAccent: 'blueprint',
      accents: BLUEPRINT_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-blueprint',
      stylesheets: [
        'themes/blueprint/tokens.css',
        'themes/blueprint/shell.css',
      ],
    },
    /* The night shift. Every other Khayt design is light by default, but a farm
       runs unattended overnight and gets checked in a dim workshop — so this is
       the one theme whose defaultAppearance is 'dark', and it is designed for
       that hour rather than derived from a light theme. Hosted on Command
       because the dense monitoring layout is what that job wants. */
    nocturne: {
      labelKey: 'theme.design.nocturne',
      descKey: 'theme.design.nocturne_desc',
      preview: 'themes/previews/nocturne.png',
      shell: 'command',
      enabled: true,
      defaultAccent: 'amber',
      accents: NOCTURNE_ACCENTS,
      defaultAppearance: 'dark',
      bodyClass: 'khayt-nocturne',
      stylesheets: [
        'themes/nocturne/tokens.css',
        'themes/nocturne/shell.css',
      ],
    },
    /* The first Khayt design that is not a sidebar app. Meridian drops the left
       nav entirely, moves navigation to a horizontal bar, and replaces the card
       dashboard with a SCHEDULE — machine lanes on an hour axis with a live
       now-line. It therefore owns a shell of its own rather than borrowing one:
       shell.js builds the chrome, screens.js draws the timeline. */
    meridian: {
      labelKey: 'theme.design.meridian',
      descKey: 'theme.design.meridian_desc',
      preview: 'themes/previews/meridian.png',
      shell: 'meridian',
      enabled: true,
      defaultAccent: 'signal',
      accents: MERIDIAN_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-meridian',
      stylesheets: [
        'themes/meridian/tokens.css',
        'themes/meridian/shell.css',
      ],
    },
    /* A home you EMPTY rather than read. Foreman's dashboard is a ranked docket
       of decisions beside a detail pane, with a count that follows you onto
       every screen and keyboard triage — a different model from a dashboard,
       and a different one again from Meridian's schedule. Keeps the sidebar:
       two shells removing it would be one idea used twice. */
    flow: {
      labelKey: 'theme.design.flow',
      descKey: 'theme.design.flow_desc',
      preview: 'themes/previews/flow.png',
      shell: 'flow',
      enabled: true,
      defaultAccent: 'tide',
      accents: FLOW_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-flow',
      stylesheets: [
        'themes/flow/tokens.css',
        'themes/flow/shell.css',
      ],
    },
    foreman: {
      labelKey: 'theme.design.foreman',
      descKey: 'theme.design.foreman_desc',
      preview: 'themes/previews/foreman.png',
      shell: 'foreman',
      enabled: true,
      defaultAccent: 'pine',
      accents: FOREMAN_ACCENTS,
      defaultAppearance: 'light',
      bodyClass: 'khayt-foreman',
      stylesheets: [
        'themes/foreman/tokens.css',
        'themes/foreman/shell.css',
      ],
    },
  };

  const registry = { ...BUILTIN_THEMES, ...RESERVED_THEMES };
  const customThemes = {};

  function isCustomThemeId(themeId) {
    return typeof themeId === 'string' && themeId.startsWith('custom:');
  }

  function customIdFromTheme(themeId) {
    return isCustomThemeId(themeId) ? themeId.slice(7) : null;
  }

  function normalizeDesignId(designId) {
    if (!designId) return DEFAULT_DESIGN;
    // 'classic' was the pre-2.6 name for ledger, which the legacy-theme
    // deletion removed; its users land on the default like any other stale id.
    if (designId === 'classic') return DEFAULT_DESIGN;
    if (isCustomThemeId(designId)) {
      const id = customIdFromTheme(designId);
      return customThemes[id] ? designId : DEFAULT_DESIGN;
    }
    const theme = registry[designId];
    if (!theme || theme.enabled === false) return DEFAULT_DESIGN;
    return designId;
  }

  function getTheme(designId) {
    const id = normalizeDesignId(designId);
    if (isCustomThemeId(id)) return customThemes[customIdFromTheme(id)];
    // Bed Ready left with the studio theme in 3.3; the default is the fallback now.
    return registry[id] || registry[DEFAULT_DESIGN];
  }

  /**
   * The theme entry EXACTLY as registered, without normalising the id.
   *
   * getTheme() normalises first, and normalizeDesignId() maps anything
   * `enabled: false` onto workbench — correct when resolving what to RENDER
   * (you must never apply a disabled theme), wrong when describing a theme.
   * The picker's coming-soon cards went through getTheme(), so Pulse and Stream
   * both drew Workbench's name and description under a COMING SOON badge.
   *
   * Use this for LABELLING a theme; keep getTheme() for applying one.
   */
  function getThemeDefinition(designId) {
    if (isCustomThemeId(designId)) return customThemes[customIdFromTheme(designId)] || null;
    return registry[designId] || null;
  }

  function listSelectableThemes() {
    const builtins = Object.entries(registry)
      .filter(([, t]) => t.enabled !== false && !t.comingSoon && !t.legacy)
      .map(([id]) => id);
    const custom = Object.keys(customThemes).map((id) => `custom:${id}`);
    return [...builtins, ...custom];
  }

  function listComingSoonThemes() {
    return Object.entries(registry)
      .filter(([, t]) => t.comingSoon)
      .map(([id]) => id);
  }

  function accentsForTheme(designId) {
    return getTheme(designId).accents || WORKBENCH_ACCENTS;
  }

  function defaultAccentForTheme(designId) {
    return getTheme(designId).defaultAccent || 'cyan';
  }

  function normalizeAccent(designId, accentId) {
    const set = accentsForTheme(designId);
    if (accentId && set[accentId]) return accentId;
    return defaultAccentForTheme(designId);
  }

  function validateCustomManifest(manifest) {
    if (!manifest || typeof manifest !== 'object') return ['manifest must be an object'];
    const errors = [];
    if (!manifest.id || !/^[a-z][a-z0-9-]{1,31}$/.test(manifest.id)) errors.push('id must be lowercase slug (2–32 chars)');
    if (!manifest.name || typeof manifest.name !== 'string') errors.push('name is required');
    if (!manifest.tokens || typeof manifest.tokens !== 'string') errors.push('tokens css path required');
    // Stylesheet refs must be plain .css filenames inside the theme folder — block path traversal.
    const SAFE_CSS = /^[a-zA-Z0-9._-]+\.css$/;
    for (const f of ['tokens', 'compat', 'shellCss']) {
      if (manifest[f] && !SAFE_CSS.test(manifest[f])) errors.push(`${f} must be a .css filename (no path separators)`);
    }
    if (manifest.bodyClass && !/^[a-zA-Z][\w-]{0,63}$/.test(manifest.bodyClass)) errors.push('bodyClass must be a simple class name');
    if (manifest.accents !== undefined) {
      if (typeof manifest.accents !== 'object' || manifest.accents === null || Array.isArray(manifest.accents)) {
        errors.push('accents must be an object');
      } else {
        const isPct = (v) => (typeof v === 'number' && v >= 0 && v <= 100)
          || (typeof v === 'string' && /^\d{1,3}(\.\d+)?%$/.test(v.trim()));
        for (const [key, a] of Object.entries(manifest.accents)) {
          if (!a || typeof a !== 'object') { errors.push(`accent "${key}" must be an object`); continue; }
          const h = Number(a.h);
          if (!Number.isFinite(h) || h < 0 || h > 360) errors.push(`accent "${key}".h must be a number 0–360`);
          if (!isPct(a.s)) errors.push(`accent "${key}".s must be a percentage`);
          if (!isPct(a.l)) errors.push(`accent "${key}".l must be a percentage`);
        }
      }
    }
    // Shells a custom theme may adopt. 'ledger' was accepted here until the 3.3
    // legacy deletion removed it — a manifest naming it would have validated and
    // then rendered nothing. 'studio' stays out: it is Bed Ready's, not Khayt's.
    if (manifest.shell && !CUSTOM_THEME_SHELLS.includes(manifest.shell)) {
      errors.push(`shell must be one of: ${CUSTOM_THEME_SHELLS.join(', ')}`);
    }
    return errors;
  }

  /**
   * @param {object} manifest
   * @param {string|null} basePath  where its stylesheets can be linked from, or
   *   null for a theme installed in userData — those have no URL the renderer is
   *   allowed to fetch, so their CSS arrives as text over IPC instead.
   * @param {Array<{name:string,text:string}>} [inlineCss] that text
   */
  function registerCustomTheme(manifest, basePath = 'themes/custom', inlineCss = null) {
    const errors = validateCustomManifest(manifest);
    if (errors.length) return { ok: false, errors };
    const id = manifest.id;
    if (registry[id] || customThemes[id]) return { ok: false, errors: ['id already registered'] };

    const accents = {};
    const sourceAccents = manifest.accents || {
      brand: { h: 200, s: '70%', l: '50%', label: manifest.name },
    };
    Object.entries(sourceAccents).forEach(([key, a]) => {
      accents[key] = {
        h: a.h,
        s: a.s,
        l: a.l,
        labelKey: a.labelKey || `theme.custom.${id}.${key}`,
        label: a.label || key,
      };
    });

    const shell = manifest.shell || 'default';
    const bodyClass = manifest.bodyClass || `khayt-custom-${id}`;
    // A theme installed in userData has no linkable URL: userData is outside the
    // app's origin, and the CSP that keeps a stray <link> from reaching the
    // network is the same one that stops it reaching the disk. Its CSS comes
    // over IPC as text and is injected; a bundled one still links, unchanged.
    const stylesheets = [];
    if (basePath) {
      stylesheets.push(`${basePath}/${id}/${manifest.tokens}`);
      if (manifest.compat) stylesheets.push(`${basePath}/${id}/${manifest.compat}`);
      if (manifest.shellCss) stylesheets.push(`${basePath}/${id}/${manifest.shellCss}`);
    }

    customThemes[id] = {
      id,
      labelKey: manifest.labelKey || `theme.custom.${id}.name`,
      descKey: manifest.descKey || `theme.custom.${id}.desc`,
      label: manifest.name,
      description: manifest.description || '',
      shell,
      enabled: true,
      custom: true,
      defaultAccent: manifest.defaultAccent || Object.keys(accents)[0],
      accents,
      defaultAppearance: manifest.defaultAppearance || 'dark',
      bodyClass,
      stylesheets,
      inlineCss: Array.isArray(inlineCss) ? inlineCss : null,
      manifest,
    };
    return { ok: true, id: `custom:${id}` };
  }

  function registerBuiltinTheme(id, def) {
    if (!id || registry[id]) return false;
    registry[id] = { enabled: true, ...def };
    return true;
  }

  const api = {
    DEFAULT_DESIGN,
    KHAYT_ACCENTS,
    WORKBENCH_ACCENTS,
    VIVID_ACCENTS,
    COMMAND_ACCENTS,
    BUILTIN_THEMES,
    RESERVED_THEMES,
    registry,
    customThemes,
    isCustomThemeId,
    customIdFromTheme,
    normalizeDesignId,
    getTheme,
    getThemeDefinition,
    listSelectableThemes,
    listComingSoonThemes,
    accentsForTheme,
    defaultAccentForTheme,
    normalizeAccent,
    validateCustomManifest,
    registerCustomTheme,
    registerBuiltinTheme,
    CUSTOM_THEME_SHELLS,
  };

  Object.assign(global, api);
  global.KhaytThemeRegistry = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
