/* Khayt Studio — line icons (ported from design/khayt/icons.jsx) */
(function () {
  const STROKE = 'fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"';

  const ICONS = {
    dashboard: '<rect x="3" y="3" width="7" height="9" rx="1.4"/><rect x="14" y="3" width="7" height="5" rx="1.4"/><rect x="14" y="12" width="7" height="9" rx="1.4"/><rect x="3" y="16" width="7" height="5" rx="1.4"/>',
    calculator: '<rect x="4" y="2.5" width="16" height="19" rx="2.4"/><rect x="7.5" y="5.5" width="9" height="3.2" rx="1"/><path d="M8 13h0M12 13h0M16 13h0M8 17h0M12 17h0M16 17h0"/>',
    queue: '<rect x="3" y="4" width="5" height="16" rx="1.3"/><rect x="9.5" y="4" width="5" height="11" rx="1.3"/><rect x="16" y="4" width="5" height="14" rx="1.3"/>',
    orders: '<path d="M8 4h11M8 9h11M8 15h11M8 20h11"/><path d="M3.5 4h.01M3.5 9h.01M3.5 15h.01M3.5 20h.01"/>',
    analytics: '<path d="M4 20V4"/><path d="M4 20h16"/><path d="M8 16l3.5-4 3 2.5L20 8"/>',
    inventory: '<path d="M3.5 7.5 12 3l8.5 4.5v9L12 21l-8.5-4.5z"/><path d="M3.5 7.5 12 12l8.5-4.5M12 12v9"/>',
    clients: '<circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c.6-3.3 2.9-5 5.5-5s4.9 1.7 5.5 5"/><path d="M16 5.2A3 3 0 0 1 16 11M20.5 19c-.4-2.2-1.6-3.7-3.2-4.4"/>',
    portfolio: '<rect x="3" y="4.5" width="18" height="15" rx="2.2"/><circle cx="8.5" cy="10" r="1.6"/><path d="m4 17 4.5-4 3.5 3 3-2.5L20 17"/>',
    expenses: '<path d="M5 3.5h14v17l-2.3-1.5-2.3 1.5-2.4-1.5L9.6 20l-2.3-1.5L5 20z"/><path d="M9 8h6M9 12h6"/>',
    waste: '<path d="M4 7h16M9.5 7V5.2c0-.7.5-1.2 1.2-1.2h2.6c.7 0 1.2.5 1.2 1.2V7"/><path d="M6 7l1 12.5c0 .8.6 1.5 1.5 1.5h7c.9 0 1.5-.7 1.5-1.5L18 7"/>',
    gift: '<rect x="3.5" y="8.5" width="17" height="5" rx="1.2"/><path d="M5 13.5V20h14v-6.5M12 8.5V21"/><path d="M12 8.5S10.5 4 8.2 4.5C6.8 4.8 6.8 7 8 8.5zM12 8.5S13.5 4 15.8 4.5C17.2 4.8 17.2 7 16 8.5z"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 13a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1V20a2 2 0 1 1-4 0v-.2a1.6 1.6 0 0 0-2.7-1.1l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.6 1.6 0 0 0 4 13H3.8a2 2 0 1 1 0-4H4a1.6 1.6 0 0 0 1.1-2.7l-.1-.1A2 2 0 1 1 7.7 3.4l.1.1A1.6 1.6 0 0 0 10 4V3.8a2 2 0 1 1 4 0V4a1.6 1.6 0 0 0 2.7 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1A1.6 1.6 0 0 0 20 10h.2a2 2 0 1 1 0 4H20a1.6 1.6 0 0 0-.6 0z"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-3.5-3.5"/>',
    bell: '<path d="M6 9a6 6 0 0 1 12 0c0 5 2 6 2 6H4s2-1 2-6"/><path d="M10.5 19a1.8 1.8 0 0 0 3 0"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    chevdown: '<path d="m6 9 6 6 6-6"/>',
    chevright: '<path d="m9 6 6 6-6 6"/>',
    printer: '<path d="M7 9V3.5h10V9"/><rect x="4" y="9" width="16" height="8" rx="1.8"/><path d="M7 15h10v5.5H7z"/><circle cx="17" cy="12" r=".9" fill="currentColor" stroke="none"/>',
    spool: '<rect x="5" y="3.5" width="14" height="17" rx="2"/><circle cx="12" cy="12" r="4.2"/><circle cx="12" cy="12" r="1.2"/><path d="M5 7h14M5 17h14"/>',
    clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
    check: '<path d="m4.5 12.5 5 5 10-11"/>',
    alert: '<path d="M12 3.5 21 19H3z"/><path d="M12 10v4M12 17h.01"/>',
    filter: '<path d="M4 5h16l-6.4 7.6V19l-3.2 1.5v-7.9z"/>',
    pin: '<path d="M12 21s7-5.5 7-11a7 7 0 1 0-14 0c0 5.5 7 11 7 11z"/><circle cx="12" cy="10" r="2.5"/>',
    user: '<circle cx="12" cy="8" r="3.5"/><path d="M5 20c.7-3.8 3.4-6 7-6s6.3 2.2 7 6"/>',
    globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 2.3 2.5 14.7 0 17M12 3.5c-2.5 2.3-2.5 14.7 0 17"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.5 4.5l1.4 1.4M18.1 18.1l1.4 1.4M2.5 12h2M19.5 12h2M4.5 19.5l1.4-1.4M18.1 5.9l1.4-1.4"/>',
    moon: '<path d="M20 14.5A8 8 0 1 1 9.5 4 6.5 6.5 0 0 0 20 14.5z"/>',
    more: '<circle cx="5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
    grip: '<circle cx="9" cy="6" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="6" r="1.3" fill="currentColor" stroke="none"/><circle cx="9" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="12" r="1.3" fill="currentColor" stroke="none"/><circle cx="9" cy="18" r="1.3" fill="currentColor" stroke="none"/><circle cx="15" cy="18" r="1.3" fill="currentColor" stroke="none"/>',
    arrowup: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    arrowdown: '<path d="M12 5v14M6 13l6 6 6-6"/>',
    bolt: '<path d="M13 2.5 4.5 13.5H11l-1 8 8.5-11H12z"/>',
    cube: '<path d="M3.5 7.5 12 3l8.5 4.5v9L12 21l-8.5-4.5z"/><path d="M3.5 7.5 12 12l8.5-4.5M12 12v9"/>',
    doc: '<path d="M6 2.5h8l4 4V21H6z"/><path d="M14 2.5V7h4M9 12h6M9 16h6"/>',
    edit: '<path d="M4 20h4L19 9a2 2 0 0 0-3-3L5 17z"/><path d="M14.5 6.5 17.5 9.5"/>',
    link: '<path d="M9.5 14.5 14.5 9.5"/><path d="M8 11 6 13a3.5 3.5 0 0 0 5 5l2-2M16 13l2-2a3.5 3.5 0 0 0-5-5l-2 2"/>',
    trend: '<path d="M3 16l5-5 3.5 3L21 5"/><path d="M15 5h6v6"/>',
    flame: '<path d="M12 21c3.5 0 6-2.4 6-5.6 0-3.4-2.6-5-3.8-8.4-.3 2-1.6 3.2-2.8 4.2C9.7 8.7 9.3 6.5 10 4 6.5 6 6 10 6 12.4 6 16.4 8.5 21 12 21z"/>',
    pause: '<rect x="7" y="5" width="3.5" height="14" rx="1"/><rect x="13.5" y="5" width="3.5" height="14" rx="1"/>',
    camera: '<path d="M4 8h3l1.5-2.2h7L17 8h3v11H4z"/><circle cx="12" cy="13" r="3.2"/>',
    close: '<path d="m6 6 12 12M18 6 6 18"/>',
    catalog: '<path d="M3.5 7.5 12 3l8.5 4.5v9L12 21l-8.5-4.5z"/><path d="M3.5 7.5 12 12l8.5-4.5M12 12v9"/>',
    swap: '<path d="M4 8.5h13M14 5l3.5 3.5L14 12"/><path d="M20 15.5H7M10 12l-3.5 3.5L10 19"/>',
    palette: '<circle cx="9" cy="9.5" r="4.3"/><circle cx="15" cy="9.5" r="4.3"/><circle cx="12" cy="14.7" r="4.3"/>',
    image: '<rect x="3" y="4.5" width="18" height="15" rx="2"/><circle cx="8.5" cy="9.5" r="1.7"/><path d="m4 17 5-5 3.2 3.2L16 11l4 4.5"/>',
  };

  const TAB_ICON = {
    'dashboard-tab': 'dashboard',
    'queue-tab': 'queue',
    'calculator-tab': 'calculator',
    'inventory-tab': 'inventory',
    'catalog-tab': 'catalog',
    'waste-tab': 'waste',
    'logs-tab': 'orders',
    'clients-tab': 'clients',
    'gift-cards-tab': 'gift',
    'portfolio-tab': 'portfolio',
    'analytics-tab': 'analytics',
    'expenses-tab': 'expenses',
    'settings-tab': 'settings',
  };

  function svg(name, size, strokeWidth) {
    const inner = ICONS[name];
    if (!inner) return '';
    const sw = strokeWidth != null ? strokeWidth : 1.7;
    const stroke = `fill="none" stroke="currentColor" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"`;
    return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" ${stroke} style="flex-shrink:0;display:block" aria-hidden="true">${inner}</svg>`;
  }

  function mount(el, name, size) {
    if (!el || !name) return;
    el.innerHTML = svg(name, size || 18);
  }

  const SETTINGS_ICON = {
    biz: 'doc',
    prefs: 'settings',
    stock: 'inventory',
    invoice: 'doc',
    payments: 'gift',
    printers: 'printer',
    online: 'globe',
    ops: 'bolt',
    automation: 'bell',
    access: 'user',
    data: 'doc',
  };

  function hydrateSettingsNav() {
    if (!document.body.classList.contains('bedready-ui')) return;
    document.querySelectorAll('.settings-nav-item[data-settings-section]').forEach((btn) => {
      const iconEl = btn.querySelector('.nav-icon');
      const name = SETTINGS_ICON[btn.dataset.settingsSection];
      if (iconEl && name) mount(iconEl, name, 16);
    });
  }


  function hydrateHandoff() {
    if (!document.body.classList.contains('bedready-ui')) return;
    if (document.body.classList.contains('bedready-ui')) {
      hydrateNav();
      hydrateTopbar();
    }
    hydrateSettingsNav();
  }

  function hydrateNav() {
    if (!document.body.classList.contains('bedready-ui')) return;
    document.querySelectorAll('.khayt-navitem[data-tab]').forEach(btn => {
      const iconEl = btn.querySelector('.nav-icon');
      if (!iconEl) return;
      const name = btn.dataset.icon || TAB_ICON[btn.dataset.tab];
      if (name) mount(iconEl, name, 18);
    });
  }

  function hydrateTopbar() {
    if (!document.body.classList.contains('bedready-ui')) return;
    const themeBtn = $('#themeToggle');
    if (themeBtn) {
      themeBtn.classList.add('khayt-icon-btn');
      themeBtn.innerHTML = '';
      const isLight = document.documentElement.getAttribute('data-theme') === 'light';
      mount(themeBtn, isLight ? 'moon' : 'sun', 18);
    }
    const searchIcon = document.querySelector('.khayt-search > span[aria-hidden]');
    if (searchIcon) mount(searchIcon, 'search', 16);
    const bellBtn = $('#btnNotifBell');
    if (bellBtn) {
      bellBtn.innerHTML = '';
      mount(bellBtn, 'bell', 18);
    }
    const feedbackBtn = $('#btnFeedback');
    if (feedbackBtn) {
      feedbackBtn.textContent = '';
      mount(feedbackBtn, 'doc', 16);
      feedbackBtn.setAttribute('title', feedbackBtn.getAttribute('title') || 'Feedback');
      feedbackBtn.setAttribute('aria-label', 'Feedback');
    }
  }

  window.KhaytIcon = {
    svg, mount, hydrateNav, hydrateTopbar, hydrateSettingsNav, hydrateHandoff, ICONS,
  };
})();
