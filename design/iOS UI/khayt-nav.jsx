// khayt-nav.jsx — NavBar, TabBar, BottomSheet, ConnectionBanner
// Exports: NavBar, LargeNavBar, TabBar, BottomSheet, ConnectionBanner

// React hooks come from khayt-i18n.jsx (shared scope).

// ─── NavBar ────────────────────────────────────────────────────────────────────

function NavBar({ title, subtitle, back, onBack, right, onRight, children }) {
  const { t, dark, rtl } = useTheme();
  return (
    <div style={{
      flexShrink: 0,
      paddingTop: 62,
      background: dark ? t.navBg : t.navBg,
      backdropFilter: 'blur(20px) saturate(180%)',
      WebkitBackdropFilter: 'blur(20px) saturate(180%)',
      borderBottom: `0.5px solid ${t.sep}`,
    }}>
      <div style={{
        display: 'flex', alignItems: 'center',
        padding: '6px 16px 10px', gap: 6, minHeight: 44,
      }}>
        {back && (
          <button onClick={onBack} style={{
            display: 'flex', alignItems: 'center', gap: 3,
            background: 'none', border: 'none', cursor: 'pointer',
            color: t.brand, padding: '4px 8px 4px 0', flexShrink: 0,
            fontSize: 17, fontWeight: 400,
          }}>
            <svg width="9" height="16" viewBox="0 0 9 16" fill="none" style={{ transform: rtl ? 'scaleX(-1)' : 'none' }}>
              <path d="M7.5 1.5L1 8l6.5 6.5" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
            {typeof back === 'string' ? <span>{back}</span> : null}
          </button>
        )}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            fontSize: 17, fontWeight: 600, color: t.label,
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
            lineHeight: 1.3,
          }}>{title}</div>
          {subtitle && (
            <div style={{ fontSize: 11, color: t.label2, marginTop: 1 }}>{subtitle}</div>
          )}
        </div>
        {children}
        {right && (
          <button onClick={onRight} style={{
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            width: 32, height: 32, borderRadius: 10,
            background: t.brandDim, border: 'none', cursor: 'pointer',
            color: t.brand, flexShrink: 0,
          }}>
            {right}
          </button>
        )}
      </div>
    </div>
  );
}

function LargeNavBar({ title, badge, right, onRight }) {
  const { t, dark } = useTheme();
  return (
    <div style={{
      flexShrink: 0,
      paddingTop: 62,
      background: dark ? t.navBg : t.navBg,
      backdropFilter: 'blur(20px) saturate(180%)',
      WebkitBackdropFilter: 'blur(20px) saturate(180%)',
    }}>
      <div style={{
        display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between',
        padding: '2px 16px 12px',
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{
            fontSize: 30, fontWeight: 700, color: t.label,
            letterSpacing: -0.6, lineHeight: 1,
          }}>{title}</div>
          {badge}
        </div>
        {right && (
          <button onClick={onRight} style={{
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            width: 32, height: 32, borderRadius: 10,
            background: t.brandDim, border: 'none', cursor: 'pointer',
            color: t.brand,
          }}>
            {right}
          </button>
        )}
      </div>
    </div>
  );
}

// ─── Tab Bar ──────────────────────────────────────────────────────────────────

const TAB_DEFS = [
  {
    id: 'home', label: 'Home',
    icon: (fill, stroke) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <path d="M3 10.182L12 3l9 7.182V20a1 1 0 01-1 1H5a1 1 0 01-1-1v-9.818z" stroke={stroke} strokeWidth="1.7" fill={fill}/>
        <path d="M9 21V14h6v7" stroke={stroke} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    ),
  },
  {
    id: 'orders', label: 'Orders',
    icon: (fill, stroke) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <rect x="4" y="2.5" width="16" height="19" rx="2.5" stroke={stroke} strokeWidth="1.7" fill={fill}/>
        <path d="M8 8.5h8M8 12.5h8M8 16.5h5" stroke={stroke} strokeWidth="1.7" strokeLinecap="round"/>
      </svg>
    ),
  },
  {
    id: 'inventory', label: 'Inventory',
    icon: (fill, stroke) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <path d="M21 7.5L12 3 3 7.5v9L12 21l9-4.5v-9z" stroke={stroke} strokeWidth="1.7" strokeLinejoin="round" fill={fill}/>
        <path d="M3 7.5l9 4.5 9-4.5M12 12v9" stroke={stroke} strokeWidth="1.7" strokeLinejoin="round"/>
      </svg>
    ),
  },
  {
    id: 'machines', label: 'Machines',
    icon: (fill, stroke) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <rect x="2" y="7" width="20" height="13" rx="2.5" stroke={stroke} strokeWidth="1.7" fill={fill}/>
        <path d="M7 4h10" stroke={stroke} strokeWidth="1.7" strokeLinecap="round"/>
        <circle cx="12" cy="13.5" r="2.5" stroke={stroke} strokeWidth="1.7"/>
        <path d="M7 13.5h2.5M14.5 13.5H17" stroke={stroke} strokeWidth="1.7" strokeLinecap="round"/>
      </svg>
    ),
  },
  {
    id: 'settings', label: 'Settings',
    icon: (fill, stroke) => (
      <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
        <circle cx="12" cy="12" r="3" stroke={stroke} strokeWidth="1.7" fill={fill}/>
        <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06A1.65 1.65 0 004.68 15a1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06A1.65 1.65 0 009 4.68a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06A1.65 1.65 0 0019.4 9a1.65 1.65 0 001.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1z" stroke={stroke} strokeWidth="1.5"/>
      </svg>
    ),
  },
];

function TabBar({ activeTab, onTabChange }) {
  const { t, dark, s } = useTheme();
  return (
    <div style={{
      flexShrink: 0,
      background: dark ? t.tabBg : t.tabBg,
      backdropFilter: 'blur(24px) saturate(200%)',
      WebkitBackdropFilter: 'blur(24px) saturate(200%)',
      borderTop: `0.5px solid ${t.sep}`,
      display: 'flex',
      paddingBottom: 22,
    }}>
      {TAB_DEFS.map(tab => {
        const active = activeTab === tab.id;
        const color = active ? t.brand : t.label3;
        const fill = active ? t.brandDim : 'none';
        return (
          <button key={tab.id} onClick={() => onTabChange(tab.id)} style={{
            flex: 1, display: 'flex', flexDirection: 'column',
            alignItems: 'center', gap: 3,
            padding: '9px 4px 0',
            background: 'none', border: 'none', cursor: 'pointer',
            minHeight: 49, WebkitTapHighlightColor: 'transparent',
          }}>
            {tab.icon(fill, color)}
            <span style={{
              fontSize: 10, fontWeight: active ? 600 : 400,
              color, lineHeight: 1, letterSpacing: 0.1,
            }}>{s('tab_' + tab.id)}</span>
          </button>
        );
      })}
    </div>
  );
}

// ─── Bottom Sheet ──────────────────────────────────────────────────────────────

function BottomSheet({ visible, onDismiss, title, children, minHeight }) {
  const { t, dark } = useTheme();
  const [mounted, setMounted] = useState(false);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (visible) {
      setMounted(true);
      requestAnimationFrame(() => requestAnimationFrame(() => setOpen(true)));
    } else {
      setOpen(false);
      const timer = setTimeout(() => setMounted(false), 340);
      return () => clearTimeout(timer);
    }
  }, [visible]);

  if (!mounted) return null;

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 200,
      display: 'flex', flexDirection: 'column', justifyContent: 'flex-end',
      pointerEvents: open ? 'all' : 'none',
    }}>
      <div onClick={onDismiss} style={{
        position: 'absolute', inset: 0,
        background: 'rgba(0,0,0,0.55)',
        opacity: open ? 1 : 0,
        transition: 'opacity 0.28s ease',
      }} />
      <div style={{
        position: 'relative', zIndex: 1,
        background: dark ? '#1E1E28' : '#FFFFFF',
        borderRadius: '22px 22px 0 0',
        transform: open ? 'translateY(0)' : 'translateY(105%)',
        transition: 'transform 0.34s cubic-bezier(0.32,0.72,0,1)',
        maxHeight: '88%',
        display: 'flex', flexDirection: 'column',
        minHeight: minHeight,
        boxShadow: '0 -4px 32px rgba(0,0,0,0.4)',
      }}>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '10px 0 6px', flexShrink: 0 }}>
          <div style={{ width: 38, height: 4, borderRadius: 2, background: t.label4 }} />
        </div>
        {title && (
          <div style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between',
            padding: '0 16px 12px', flexShrink: 0,
            borderBottom: `0.5px solid ${t.sep}`,
          }}>
            <div style={{ fontSize: 17, fontWeight: 600, color: t.label }}>{title}</div>
            <button onClick={onDismiss} style={{
              width: 28, height: 28, borderRadius: 14,
              background: t.surface3, border: 'none', cursor: 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              color: t.label2, fontSize: 15, fontWeight: 600,
            }}>✕</button>
          </div>
        )}
        <div style={{ flex: 1, overflowY: 'auto', overflowX: 'hidden' }}>
          {children}
        </div>
      </div>
    </div>
  );
}

// ─── Connection Banner ─────────────────────────────────────────────────────────

function ConnectionBanner({ onRetry }) {
  const { t, s } = useTheme();
  return (
    <div style={{
      flexShrink: 0,
      background: t.errorDim,
      borderBottom: `1px solid ${t.error}33`,
      padding: '7px 16px',
      display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <div style={{ width: 7, height: 7, borderRadius: '50%', background: t.error, flexShrink: 0 }} />
        <div>
          <div style={{ fontSize: 12, fontWeight: 600, color: t.error }}>{s('desktopOffline')}</div>
          <div style={{ fontSize: 11, color: t.label2, marginTop: 1 }}>{s('checkDesktop')}</div>
        </div>
      </div>
      <button onClick={onRetry} style={{
        background: t.error, color: '#fff', border: 'none',
        borderRadius: 8, padding: '5px 11px', fontSize: 12, fontWeight: 600,
        cursor: 'pointer', flexShrink: 0,
      }}>{s('retry')}</button>
    </div>
  );
}

// ─── Scroll container ─────────────────────────────────────────────────────────

function ScrollView({ children, style: extraStyle = {} }) {
  return (
    <div style={{
      flex: 1, overflowY: 'auto', overflowX: 'hidden',
      WebkitOverflowScrolling: 'touch',
      ...extraStyle,
    }}>
      {children}
    </div>
  );
}

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, {
  NavBar, LargeNavBar, TabBar, BottomSheet, ConnectionBanner, ScrollView, TAB_DEFS,
});
