// khayt-home.jsx — Home / Dashboard screen
// Exports: HomeScreen

// React hooks come from khayt-i18n.jsx (shared scope).

// ─── Stat Block ───────────────────────────────────────────────────────────────

function StatBlock({ value, label, color, sub }) {
  const { t } = useTheme();
  return (
    <div style={{
      flex: 1, background: t.surface, borderRadius: 16,
      padding: '14px 14px 12px', display: 'flex', flexDirection: 'column', gap: 4,
    }}>
      <div style={{
        fontSize: 42, fontWeight: 700, color,
        lineHeight: 1, letterSpacing: -1, fontVariantNumeric: 'tabular-nums',
      }}>{value}</div>
      <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, letterSpacing: 0.2 }}>{label}</div>
      {sub && (
        <div style={{ fontSize: 10, color: t.label3, marginTop: 1 }}>{sub}</div>
      )}
    </div>
  );
}

// ─── Kanban Flow Strip ─────────────────────────────────────────────────────────

function KanbanStrip({ counts, onStageClick }) {
  const { t, lang } = useTheme();
  const stages = STAGE_SEQUENCE;
  return (
    <div style={{
      display: 'flex', alignItems: 'center',
      padding: '12px 16px', gap: 0, overflowX: 'auto',
    }}>
      {stages.map((stage, i) => {
        const s = STAGES[stage];
        const count = counts[stage] || 0;
        const active = count > 0;
        return (
          <React.Fragment key={stage}>
            <button
              onClick={() => onStageClick && onStageClick(stage)}
              style={{
                display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5,
                background: active ? s.bg : 'rgba(255,255,255,0.04)',
                border: `1.5px solid ${active ? s.dot + '40' : t.sep}`,
                borderRadius: 12,
                padding: '8px 10px',
                cursor: 'pointer', flexShrink: 0, minWidth: 52,
                transition: 'all 0.2s ease',
              }}
            >
              <div style={{
                fontSize: 20, fontWeight: 700,
                color: active ? s.dot : t.label3,
                letterSpacing: -0.5, lineHeight: 1,
                fontVariantNumeric: 'tabular-nums',
              }}>{count}</div>
              <div style={{
                fontSize: 9, fontWeight: 600,
                color: active ? s.dot : t.label3,
                letterSpacing: 0.5, textTransform: lang === 'ar' ? 'none' : 'uppercase',
              }}>{lang === 'ar' && typeof STAGE_LABELS_AR !== 'undefined' ? STAGE_LABELS_AR[stage] : s.label}</div>
            </button>
            {i < stages.length - 1 && (
              <div style={{
                width: 16, display: 'flex', alignItems: 'center',
                justifyContent: 'center', flexShrink: 0,
              }}>
                <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
                  <path d="M1 5h8M5.5 1.5L9 5l-3.5 3.5" stroke={t.label4} strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
            )}
          </React.Fragment>
        );
      })}
    </div>
  );
}

// ─── Mini Order Card ──────────────────────────────────────────────────────────

function MiniOrderCard({ order, onTap }) {
  const { t } = useTheme();
  const stage = STAGES[order.status] || STAGES.pending;
  const overdue = order.overdue;
  return (
    <div
      onClick={() => onTap(order)}
      style={{
        padding: '12px 16px',
        cursor: 'pointer',
        display: 'flex', alignItems: 'center', gap: 12,
        borderLeft: `3px solid ${stage.dot}`,
        marginLeft: 16, marginRight: 16,
        background: t.surface,
        borderRadius: 14,
        marginBottom: 8,
        transition: 'opacity 0.15s',
      }}
    >
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 3 }}>
          <span style={{ fontSize: 14, fontWeight: 600, color: t.label, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {order.name}
          </span>
          {overdue && (
            <span style={{ fontSize: 10, fontWeight: 700, color: '#FF453A', background: 'rgba(255,69,58,0.16)', padding: '1px 6px', borderRadius: 6, flexShrink: 0 }}>
              OVERDUE
            </span>
          )}
        </div>
        <div style={{ fontSize: 12, color: t.label2, marginBottom: 4 }}>{order.customer}</div>
        {order.status === 'printing' && order.progress !== undefined && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <ProgressBar value={order.progress} color={stage.dot} height={3} style={{ flex: 1 }} />
            <span style={{ fontSize: 10, fontWeight: 600, color: stage.dot, flexShrink: 0 }}>{order.progress}%</span>
          </div>
        )}
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5, flexShrink: 0 }}>
        <StatusPill status={order.status} />
        <div style={{ fontSize: 11, color: t.label3 }}>{order.id}</div>
      </div>
    </div>
  );
}

// ─── Low Stock Banner ─────────────────────────────────────────────────────────

function LowStockBanner({ spools, onTap }) {
  const { t, s } = useTheme();
  if (!spools || spools.length === 0) return null;
  return (
    <div
      onClick={onTap}
      style={{
        margin: '0 16px',
        background: t.warningDim,
        border: `1px solid ${t.warning}33`,
        borderRadius: 14, padding: '11px 14px',
        display: 'flex', alignItems: 'center', gap: 12,
        cursor: 'pointer',
      }}
    >
      <div style={{
        width: 36, height: 36, borderRadius: 10,
        background: t.warningDim,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 18, flexShrink: 0,
      }}>⚠️</div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 13, fontWeight: 600, color: t.warning }}>
          {s('lowStock')} — {spools.length} {spools.length > 1 ? s('spools') : s('spool')}
        </div>
        <div style={{ fontSize: 12, color: t.label2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {spools.map(s => `${s.brand} ${s.color}`).join(', ')}
        </div>
      </div>
      <svg width="7" height="13" viewBox="0 0 7 13" fill="none" style={{ flexShrink: 0 }}>
        <path d="M1 1l5 5.5L1 12" stroke={t.label3} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    </div>
  );
}

// ─── Quick Actions ─────────────────────────────────────────────────────────────

function QuickActions({ onAddSpool, onNewOrder }) {
  const { t } = useTheme();
  const actions = [
    { label: 'Add Spool', color: t.brand, icon: '📦', onPress: onAddSpool },
    { label: 'New Order', color: t.success, icon: '📋', onPress: onNewOrder },
  ];
  return (
    <div style={{ display: 'flex', gap: 10, padding: '0 16px' }}>
      {actions.map(a => (
        <button key={a.label} onClick={a.onPress} style={{
          flex: 1, padding: '12px 8px',
          background: t.surface, borderRadius: 14,
          border: 'none', cursor: 'pointer',
          display: 'flex', alignItems: 'center', gap: 8,
        }}>
          <span style={{ fontSize: 20 }}>{a.icon}</span>
          <span style={{ fontSize: 14, fontWeight: 600, color: t.label }}>{a.label}</span>
        </button>
      ))}
    </div>
  );
}

// ─── Connection Dot Badge ──────────────────────────────────────────────────────

function ConnDot({ connected }) {
  const { t, s } = useTheme();
  const color = connected ? t.success : t.error;
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 5,
      background: connected ? t.successDim : t.errorDim,
      border: `1px solid ${color}33`,
      borderRadius: 100, padding: '3px 9px',
    }}>
      <div style={{
        width: 6, height: 6, borderRadius: '50%', background: color,
        animation: connected ? 'none' : 'khayt-pulse 2s ease-in-out infinite',
      }} />
      <span style={{ fontSize: 11, fontWeight: 600, color }}>{connected ? s('connected') : s('offline')}</span>
    </div>
  );
}

// ─── Home Screen ─────────────────────────────────────────────────────────────

function HomeScreen({ onOrderTap, onGoToInventory, onGoToOrders }) {
  const { t, dark, s } = useTheme();
  const { orders, spools, connected } = useApp();

  const activeOrders = orders.filter(o => o.status !== 'completed');
  const doneToday = orders.filter(o => o.status === 'completed').length;
  const printing = orders.filter(o => o.status === 'printing').length;
  const queued = orders.filter(o => o.status === 'pending').length;
  const lowSpools = spools.filter(sp => sp.lowStock);

  const counts = STAGE_SEQUENCE.reduce((acc, st) => {
    acc[st] = orders.filter(o => o.status === st).length;
    return acc;
  }, {});

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* Nav */}
      <div style={{
        flexShrink: 0,
        paddingTop: 62,
        background: dark ? t.navBg : t.navBg,
        backdropFilter: 'blur(20px) saturate(180%)',
        WebkitBackdropFilter: 'blur(20px) saturate(180%)',
      }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', padding: '2px 16px 10px' }}>
          <div>
            <div style={{ fontSize: 11, color: t.label3, marginBottom: 2, letterSpacing: 0.4 }}>{s('appName')}</div>
            <div style={{ fontSize: 26, fontWeight: 700, color: t.label, letterSpacing: -0.5, lineHeight: 1 }}>{s('shopPulse')}</div>
          </div>
          <ConnDot connected={connected} />
        </div>
      </div>

      <ScrollView>
        {/* Stats row */}
        <div style={{ display: 'flex', gap: 10, padding: '14px 16px 0' }}>
          <StatBlock value={queued} label={s('inQueue')} color={STAGES.pending.dot} />
          <StatBlock value={printing} label={s('printingStat')} color={STAGES.printing.dot} sub={printing > 0 ? s('activeJobs') : s('noJobs')} />
          <StatBlock value={doneToday} label={s('doneToday')} color={STAGES.completed.dot} />
        </div>

        {/* Kanban strip */}
        <div style={{ marginTop: 14 }}>
          <SectionLabel text={s('pipeline')} action={s('allOrders')} onAction={onGoToOrders} style={{ marginBottom: 4 }} />
          <div style={{
            marginLeft: 16, marginRight: 16,
            background: t.surface, borderRadius: 16, overflow: 'hidden',
          }}>
            <KanbanStrip counts={counts} onStageClick={(stage) => onGoToOrders && onGoToOrders(stage)} />
          </div>
        </div>

        {/* Low stock alert */}
        {lowSpools.length > 0 && (
          <div style={{ marginTop: 14 }}>
            <LowStockBanner spools={lowSpools} onTap={onGoToInventory} />
          </div>
        )}

        {/* Active orders */}
        <div style={{ marginTop: 14 }}>
          <SectionLabel text={s('activeOrders')} action={s('seeAll')} onAction={onGoToOrders} />
          {activeOrders.length === 0 ? (
            <EmptyState icon="✓" title={s('allClear')} subtitle={s('noActiveNow')} />
          ) : (
            activeOrders.slice(0, 4).map(order => (
              <MiniOrderCard key={order.id} order={order} onTap={onOrderTap} />
            ))
          )}
        </div>

        <div style={{ height: 24 }} />
      </ScrollView>
    </div>
  );
}

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, { HomeScreen });
