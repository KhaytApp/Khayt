// khayt-design.jsx — Design tokens, theme context, base UI components
// Exports: ThemeContext, useTheme, AppContext, useApp, NavContext, useNav,
//          DARK_TOKENS, LIGHT_TOKENS, STAGES, STAGE_SEQUENCE,
//          StatusPill, SectionLabel, Card, ProgressBar, EmptyState, Skeleton

// React hooks come from khayt-i18n.jsx (shared scope) — do not re-declare here.

// ─── Design Tokens ────────────────────────────────────────────────────────────

const DARK_TOKENS = {
  bg:         '#0C0C0F',
  bg2:        '#141418',
  surface:    '#1C1C26',
  surface2:   '#25252F',
  surface3:   '#2E2E3B',
  label:      '#FFFFFF',
  label2:     'rgba(235,235,245,0.60)',
  label3:     'rgba(235,235,245,0.32)',
  label4:     'rgba(235,235,245,0.16)',
  sep:        'rgba(255,255,255,0.08)',
  brand:      '#8183FF',
  brandDim:   'rgba(129,131,255,0.16)',
  brandText:  '#A5A8FF',
  success:    '#32D74B',
  successDim: 'rgba(50,215,75,0.16)',
  warning:    '#FFD60A',
  warningDim: 'rgba(255,214,10,0.16)',
  error:      '#FF453A',
  errorDim:   'rgba(255,69,58,0.16)',
  orange:     '#FF9F0A',
  orangeDim:  'rgba(255,159,10,0.16)',
  purple:     '#BF5AF2',
  purpleDim:  'rgba(191,90,242,0.16)',
  tabBg:      'rgba(10,10,14,0.94)',
  navBg:      'rgba(12,12,16,0.92)',
};

const LIGHT_TOKENS = {
  bg:         '#F2F2F7',
  bg2:        '#E9E9EF',
  surface:    '#FFFFFF',
  surface2:   '#F2F2F7',
  surface3:   '#E5E5EA',
  label:      '#000000',
  label2:     'rgba(60,60,67,0.60)',
  label3:     'rgba(60,60,67,0.32)',
  label4:     'rgba(60,60,67,0.16)',
  sep:        'rgba(60,60,67,0.12)',
  brand:      '#5856D6',
  brandDim:   'rgba(88,86,214,0.10)',
  brandText:  '#4B49C4',
  success:    '#34C759',
  successDim: 'rgba(52,199,89,0.12)',
  warning:    '#FF9500',
  warningDim: 'rgba(255,149,0,0.12)',
  error:      '#FF3B30',
  errorDim:   'rgba(255,59,48,0.12)',
  orange:     '#FF9500',
  orangeDim:  'rgba(255,149,0,0.12)',
  purple:     '#AF52DE',
  purpleDim:  'rgba(175,82,222,0.12)',
  tabBg:      'rgba(248,248,252,0.94)',
  navBg:      'rgba(242,242,247,0.94)',
};

// Kanban stage specs — consistent across the app
const STAGES = {
  pending:   { label: 'Pending',  dot: '#8E8E93', bg: 'rgba(142,142,147,0.16)', order: 0 },
  printing:  { label: 'Printing', dot: '#8183FF', bg: 'rgba(129,131,255,0.16)', order: 1 },
  post:      { label: 'Post',     dot: '#BF5AF2', bg: 'rgba(191,90,242,0.16)',  order: 2 },
  qc:        { label: 'QC',       dot: '#FFD60A', bg: 'rgba(255,214,10,0.16)',  order: 3 },
  completed: { label: 'Done',     dot: '#32D74B', bg: 'rgba(50,215,75,0.16)',   order: 4 },
};
const STAGE_SEQUENCE = ['pending', 'printing', 'post', 'qc', 'completed'];

// ─── Contexts ──────────────────────────────────────────────────────────────────

const ThemeContext = createContext({ dark: true, t: DARK_TOKENS });
const useTheme = () => useContext(ThemeContext);

const AppContext = createContext({});
const useApp = () => useContext(AppContext);

const NavContext = createContext({});
const useNav = () => useContext(NavContext);

// ─── Base Components ───────────────────────────────────────────────────────────

function StatusPill({ status, size = 'sm' }) {
  const { lang } = useTheme();
  const stage = STAGES[status] || STAGES.pending;
  const label = (lang === 'ar' && typeof STAGE_LABELS_AR !== 'undefined') ? STAGE_LABELS_AR[status] : stage.label;
  const lg = size === 'lg';
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: lg ? 6 : 5,
      padding: lg ? '5px 11px' : '3px 8px',
      borderRadius: 100,
      background: stage.bg,
      fontSize: lg ? 13 : 11,
      fontWeight: 600,
      color: stage.dot,
      letterSpacing: 0.2,
      whiteSpace: 'nowrap',
      flexShrink: 0,
      direction: 'ltr',
    }}>
      <span style={{
        width: lg ? 7 : 6, height: lg ? 7 : 6,
        borderRadius: '50%', background: stage.dot, flexShrink: 0,
      }} />
      {label}
    </span>
  );
}

function SectionLabel({ text, action, onAction, style: extraStyle = {} }) {
  const { t } = useTheme();
  return (
    <div style={{
      display: 'flex', justifyContent: 'space-between', alignItems: 'center',
      padding: '0 16px', marginBottom: 6, ...extraStyle,
    }}>
      <span style={{
        fontSize: 12, fontWeight: 600, color: t.label2,
        letterSpacing: 0.7, textTransform: 'uppercase',
      }}>{text}</span>
      {action && (
        <button onClick={onAction} style={{
          background: 'none', border: 'none',
          fontSize: 14, fontWeight: 500, color: t.brand,
          cursor: 'pointer', padding: '2px 0',
        }}>{action}</button>
      )}
    </div>
  );
}

function Card({ children, style: extraStyle = {}, onClick }) {
  const { t } = useTheme();
  return (
    <div onClick={onClick} style={{
      background: t.surface,
      borderRadius: 16,
      overflow: 'hidden',
      cursor: onClick ? 'pointer' : undefined,
      ...extraStyle,
    }}>
      {children}
    </div>
  );
}

function ProgressBar({ value, color, height = 4, style: extraStyle = {} }) {
  const { t } = useTheme();
  return (
    <div style={{
      height, borderRadius: height,
      background: t.surface3, overflow: 'hidden', ...extraStyle,
    }}>
      <div style={{
        height: '100%', width: `${Math.min(100, Math.max(0, value))}%`,
        background: color, borderRadius: height,
        transition: 'width 0.4s ease',
      }} />
    </div>
  );
}

function EmptyState({ icon, title, subtitle, action, onAction }) {
  const { t } = useTheme();
  return (
    <div style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center',
      justifyContent: 'center', padding: '52px 32px', gap: 10, textAlign: 'center',
    }}>
      <div style={{ fontSize: 44, opacity: 0.3, marginBottom: 4, lineHeight: 1 }}>{icon}</div>
      <div style={{ fontSize: 17, fontWeight: 600, color: t.label }}>{title}</div>
      {subtitle && (
        <div style={{ fontSize: 14, color: t.label2, lineHeight: 1.5, maxWidth: 260 }}>{subtitle}</div>
      )}
      {action && (
        <button onClick={onAction} style={{
          marginTop: 8, padding: '10px 24px',
          borderRadius: 12, background: t.brand,
          color: '#fff', border: 'none',
          fontSize: 15, fontWeight: 600, cursor: 'pointer',
        }}>{action}</button>
      )}
    </div>
  );
}

function Skeleton({ width = '100%', height = 16, radius = 8, style: extraStyle = {} }) {
  const { dark } = useTheme();
  return (
    <div style={{
      width, height, borderRadius: radius,
      background: dark ? 'rgba(255,255,255,0.07)' : 'rgba(0,0,0,0.05)',
      ...extraStyle,
    }} />
  );
}

function Divider({ inset = 16 }) {
  const { t } = useTheme();
  return (
    <div style={{
      height: 0.5,
      background: t.sep,
      margin: `0 ${inset}px`,
    }} />
  );
}

// ─── Global styles injected once ──────────────────────────────────────────────
(function injectStyles() {
  const style = document.createElement('style');
  style.textContent = `
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    button { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
    input, textarea { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
    ::-webkit-scrollbar { display: none; }
    @keyframes khayt-pulse {
      0%, 100% { opacity: 0.4; transform: scale(1); }
      50% { opacity: 1; transform: scale(1.1); }
    }
    @keyframes khayt-spin {
      to { transform: rotate(360deg); }
    }
    @keyframes khayt-slide-up {
      from { transform: translateY(12px); opacity: 0; }
      to { transform: translateY(0); opacity: 1; }
    }
    @keyframes khayt-nfc-ping {
      0% { transform: scale(0.8); opacity: 0.8; }
      100% { transform: scale(2); opacity: 0; }
    }
  `;
  document.head.appendChild(style);
})();

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, {
  ThemeContext, useTheme,
  AppContext, useApp,
  NavContext, useNav,
  DARK_TOKENS, LIGHT_TOKENS,
  STAGES, STAGE_SEQUENCE,
  StatusPill, SectionLabel, Card, ProgressBar,
  EmptyState, Skeleton, Divider,
});
