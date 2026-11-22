// khayt-widget.jsx — iOS Home Screen widget concept overlay
// Exports: WidgetPreview

function KhaytMark({ size = 18, color }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none">
      <path d="M5 13L12 6l7 7" stroke={color} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/>
      <path d="M8.5 19v-6h7v6" stroke={color} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/>
    </svg>
  );
}

function WidgetConnDot({ connected, label }) {
  const color = connected ? '#32D74B' : '#FF453A';
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 5, direction: 'ltr' }}>
      <span style={{
        width: 7, height: 7, borderRadius: '50%', background: color,
        boxShadow: `0 0 6px ${color}99`,
      }} />
      {label && <span style={{ fontSize: 11, fontWeight: 600, color: 'rgba(255,255,255,0.85)' }}>{label}</span>}
    </div>
  );
}

// Small 2×2 widget — queue count + connection dot
function SmallWidget({ counts, connected, s }) {
  return (
    <div style={{
      width: 150, height: 150, borderRadius: 24,
      background: 'linear-gradient(160deg, #23232E 0%, #16161D 100%)',
      border: '1px solid rgba(255,255,255,0.06)',
      boxShadow: '0 10px 30px rgba(0,0,0,0.4)',
      padding: 16, display: 'flex', flexDirection: 'column',
      justifyContent: 'space-between',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{
          width: 26, height: 26, borderRadius: 8,
          background: 'rgba(129,131,255,0.18)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          <KhaytMark size={16} color="#A5A8FF" />
        </div>
        <WidgetConnDot connected={connected} />
      </div>
      <div>
        <div style={{ fontSize: 52, fontWeight: 700, color: '#fff', lineHeight: 0.95, letterSpacing: -2, fontVariantNumeric: 'tabular-nums', direction: 'ltr' }}>
          {counts.pending}
        </div>
        <div style={{ fontSize: 13, fontWeight: 600, color: 'rgba(255,255,255,0.6)', marginTop: 2 }}>
          {s('inQueue')}
        </div>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ width: 6, height: 6, borderRadius: '50%', background: '#8183FF', flexShrink: 0 }} />
        <span style={{ fontSize: 12, color: 'rgba(255,255,255,0.7)' }}>
          <span style={{ direction: 'ltr', display: 'inline-block' }}>{counts.printing}</span> {s('printingStat').toLowerCase()}
        </span>
      </div>
    </div>
  );
}

// Medium 4×2 widget — full pipeline + connection
function MediumWidget({ counts, connected, s, printingOrder }) {
  const stages = STAGE_SEQUENCE;
  return (
    <div style={{
      width: 322, height: 150, borderRadius: 24,
      background: 'linear-gradient(160deg, #23232E 0%, #16161D 100%)',
      border: '1px solid rgba(255,255,255,0.06)',
      boxShadow: '0 10px 30px rgba(0,0,0,0.4)',
      padding: 16, display: 'flex', flexDirection: 'column', justifyContent: 'space-between',
    }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <div style={{
            width: 24, height: 24, borderRadius: 7,
            background: 'rgba(129,131,255,0.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <KhaytMark size={15} color="#A5A8FF" />
          </div>
          <span style={{ fontSize: 13, fontWeight: 700, color: '#fff' }}>{s('shopPulse')}</span>
        </div>
        <WidgetConnDot connected={connected} label={connected ? s('connected') : s('offline')} />
      </div>

      {/* Pipeline counts */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', direction: 'ltr' }}>
        {stages.map((stage, i) => {
          const st = STAGES[stage];
          const c = counts[stage] || 0;
          return (
            <React.Fragment key={stage}>
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3 }}>
                <span style={{ fontSize: 22, fontWeight: 700, color: c > 0 ? st.dot : 'rgba(255,255,255,0.25)', lineHeight: 1, fontVariantNumeric: 'tabular-nums' }}>{c}</span>
                <span style={{ width: 5, height: 5, borderRadius: '50%', background: c > 0 ? st.dot : 'rgba(255,255,255,0.2)' }} />
              </div>
              {i < stages.length - 1 && (
                <div style={{ flex: 1, height: 1.5, background: 'rgba(255,255,255,0.08)', margin: '0 2px', marginBottom: 8 }} />
              )}
            </React.Fragment>
          );
        })}
      </div>

      {/* Active print */}
      <div style={{
        background: 'rgba(129,131,255,0.12)', borderRadius: 10,
        padding: '7px 10px', display: 'flex', alignItems: 'center', gap: 8,
      }}>
        <span style={{ width: 6, height: 6, borderRadius: '50%', background: '#8183FF', flexShrink: 0,
          animation: 'khayt-pulse 2s ease-in-out infinite' }} />
        <span style={{ fontSize: 11, color: 'rgba(255,255,255,0.85)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1 }}>
          {printingOrder ? `${printingOrder.name}` : s('noJobs')}
        </span>
        {printingOrder && (
          <span style={{ fontSize: 11, fontWeight: 700, color: '#A5A8FF', direction: 'ltr' }}>{printingOrder.progress}%</span>
        )}
      </div>
    </div>
  );
}

function WidgetPreview({ onClose }) {
  const { t, s, rtl } = useTheme();
  const { orders, connected } = useApp();

  const counts = STAGE_SEQUENCE.reduce((acc, st) => {
    acc[st] = orders.filter(o => o.status === st).length;
    return acc;
  }, {});
  const printingOrder = orders.find(o => o.status === 'printing');

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 300,
      background: 'linear-gradient(180deg, #2a2350 0%, #1a1530 45%, #0d0b1a 100%)',
      display: 'flex', flexDirection: 'column',
      animation: 'khayt-slide-up 0.3s ease',
    }}>
      {/* Status bar spacer */}
      <div style={{ height: 62, flexShrink: 0 }} />

      {/* Header */}
      <div dir={rtl ? 'rtl' : 'ltr'} style={{ padding: '4px 20px 0', display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexShrink: 0 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700, color: '#fff' }}>{s('widgetTitle')}</div>
          <div style={{ fontSize: 13, color: 'rgba(255,255,255,0.55)', marginTop: 2 }}>{s('widgetSub')}</div>
        </div>
        <button onClick={onClose} style={{
          width: 30, height: 30, borderRadius: 15,
          background: 'rgba(255,255,255,0.15)', border: 'none', cursor: 'pointer',
          color: '#fff', fontSize: 15, fontWeight: 600,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          backdropFilter: 'blur(10px)',
        }}>✕</button>
      </div>

      {/* Widgets on simulated home screen */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 22, padding: 20 }}>
        {/* Row: small + (dummy app icons) */}
        <div style={{ display: 'flex', gap: 16, alignItems: 'center' }}>
          <SmallWidget counts={counts} connected={connected} s={s} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
            {[['#8183FF', true], ['#32D74B', false], ['#FF9F0A', false]].map(([c, mark], i) => (
              <div key={i} style={{
                width: 62, height: 62, borderRadius: 15,
                background: `linear-gradient(160deg, ${c}40, ${c}15)`,
                border: '1px solid rgba(255,255,255,0.08)',
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                opacity: 0.5,
              }}>
                {mark && <KhaytMark size={26} color="rgba(255,255,255,0.5)" />}
              </div>
            ))}
          </div>
        </div>

        {/* Medium widget */}
        <MediumWidget counts={counts} connected={connected} s={s} printingOrder={printingOrder} />

        {/* Caption */}
        <div style={{
          fontSize: 12, color: 'rgba(255,255,255,0.5)', textAlign: 'center',
          maxWidth: 280, lineHeight: 1.5, direction: rtl ? 'rtl' : 'ltr',
        }}>
          {rtl
            ? 'تحدّث العناصر تلقائياً عبر الشبكة المحلية. النقطة تعرض حالة الاتصال بسطح المكتب.'
            : 'Widgets refresh over LAN. The dot shows live desktop connection — green when paired, red when offline.'}
        </div>
      </div>

      {/* Dock hint */}
      <div style={{ height: 28, flexShrink: 0 }} />
    </div>
  );
}

Object.assign(window, { WidgetPreview });
