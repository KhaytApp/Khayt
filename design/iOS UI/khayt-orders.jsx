// khayt-orders.jsx — Orders list, Order Detail sheet
// Exports: OrdersScreen

// React hooks come from khayt-i18n.jsx (shared scope).

// ─── Swipeable Row ────────────────────────────────────────────────────────────

function SwipeRow({ children, onAdvance, canAdvance }) {
  const { t, s } = useTheme();
  const [offset, setOffset] = useState(0);
  const [open, setOpen] = useState(false);
  const startX = useRef(null);
  const ACTION_W = 80;

  const onStart = (x) => { startX.current = x; };
  const onMove = (x) => {
    if (startX.current === null) return;
    const d = x - startX.current;
    if (d < 0 && canAdvance) setOffset(Math.max(d, -ACTION_W - 10));
  };
  const onEnd = () => {
    startX.current = null;
    if (offset < -ACTION_W * 0.55) { setOffset(-ACTION_W); setOpen(true); }
    else { setOffset(0); setOpen(false); }
  };
  const doAdvance = () => { setOffset(0); setOpen(false); onAdvance(); };

  return (
    <div style={{ position: 'relative', overflow: 'hidden' }}>
      {canAdvance && (
        <div style={{
          position: 'absolute', right: 0, top: 0, bottom: 0, width: ACTION_W,
          background: STAGES.printing.dot,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          flexDirection: 'column', gap: 3, cursor: 'pointer',
        }} onClick={doAdvance}>
          <svg width="18" height="14" viewBox="0 0 18 14" fill="none">
            <path d="M1 7h14M10 1l6 6-6 6" stroke="#fff" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
          <span style={{ color: '#fff', fontSize: 10, fontWeight: 700, letterSpacing: 0.5 }}>{s('advance')}</span>
        </div>
      )}
      <div
        style={{
          transform: `translateX(${offset}px)`,
          transition: startX.current !== null ? 'none' : 'transform 0.25s ease',
          background: t.surface,
        }}
        onMouseDown={e => onStart(e.clientX)}
        onMouseMove={e => startX.current !== null && onMove(e.clientX)}
        onMouseUp={onEnd}
        onMouseLeave={onEnd}
        onTouchStart={e => onStart(e.touches[0].clientX)}
        onTouchMove={e => onMove(e.touches[0].clientX)}
        onTouchEnd={onEnd}
      >
        {children}
      </div>
    </div>
  );
}

// ─── Order Row ────────────────────────────────────────────────────────────────

function OrderRow({ order, onTap, onAdvance, isLast }) {
  const { t, s } = useTheme();
  const stage = STAGES[order.status] || STAGES.pending;
  const canAdvance = order.status !== 'completed';

  return (
    <SwipeRow onAdvance={() => onAdvance(order)} canAdvance={canAdvance}>
      <div
        onClick={() => onTap(order)}
        style={{
          padding: '12px 16px', cursor: 'pointer',
          display: 'flex', alignItems: 'center', gap: 12,
          position: 'relative',
        }}
      >
        {/* Left status strip */}
        <div style={{
          width: 3, alignSelf: 'stretch', borderRadius: 2,
          background: stage.dot, flexShrink: 0,
        }} />

        {/* Content */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
            <span style={{
              fontSize: 14, fontWeight: 600, color: t.label,
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', flex: 1,
            }}>{order.name}</span>
            {order.overdue && (
              <span style={{
                fontSize: 9, fontWeight: 700, color: '#FF453A',
                background: 'rgba(255,69,58,0.15)', padding: '1px 5px', borderRadius: 4,
                flexShrink: 0, letterSpacing: 0.4,
              }}>{s('late')}</span>
            )}
          </div>
          <div style={{ fontSize: 12, color: t.label2, marginBottom: order.status === 'printing' ? 5 : 0 }}>
            {order.customer} · {order.id}
          </div>
          {order.status === 'printing' && order.progress !== undefined && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <ProgressBar value={order.progress} color={stage.dot} height={3} style={{ flex: 1 }} />
              <span style={{ fontSize: 10, fontWeight: 600, color: stage.dot, flexShrink: 0, width: 28 }}>{order.progress}%</span>
            </div>
          )}
        </div>

        {/* Right */}
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 5, flexShrink: 0 }}>
          <StatusPill status={order.status} />
          <span style={{ fontSize: 11, color: t.label3 }}>{order.dueDate}</span>
        </div>
      </div>
      {!isLast && <Divider inset={48} />}
    </SwipeRow>
  );
}

// ─── Filter Chips ──────────────────────────────────────────────────────────────

function FilterChips({ options, active, onChange }) {
  const { t } = useTheme();
  return (
    <div style={{
      display: 'flex', gap: 8, padding: '10px 16px',
      overflowX: 'auto', flexShrink: 0,
    }}>
      {options.map(opt => {
        const isActive = active === opt.id;
        const stage = opt.id !== 'all' ? STAGES[opt.id] : null;
        return (
          <button key={opt.id} onClick={() => onChange(opt.id)} style={{
            display: 'flex', alignItems: 'center', gap: 5,
            padding: '6px 12px', borderRadius: 100, flexShrink: 0,
            background: isActive
              ? (stage ? stage.bg : t.brandDim)
              : t.surface,
            border: `1.5px solid ${isActive ? (stage ? stage.dot + '50' : t.brand + '50') : t.sep}`,
            color: isActive ? (stage ? stage.dot : t.brand) : t.label2,
            fontSize: 12, fontWeight: 600, cursor: 'pointer',
            transition: 'all 0.18s ease',
          }}>
            {isActive && stage && (
              <span style={{ width: 5, height: 5, borderRadius: '50%', background: stage.dot, flexShrink: 0 }} />
            )}
            {opt.label}
            {opt.count > 0 && (
              <span style={{
                background: isActive ? (stage ? stage.dot : t.brand) : t.surface3,
                color: isActive ? '#fff' : t.label3,
                fontSize: 10, fontWeight: 700,
                borderRadius: 100, padding: '0 5px', minWidth: 16, textAlign: 'center',
              }}>{opt.count}</span>
            )}
          </button>
        );
      })}
    </div>
  );
}

// ─── Order Detail Sheet ────────────────────────────────────────────────────────

function OrderDetailContent({ order, onAdvance, onClose }) {
  const { t, s, lang } = useTheme();
  if (!order) return null;

  const stage = STAGES[order.status];
  const nextStage = STAGE_SEQUENCE[STAGE_SEQUENCE.indexOf(order.status) + 1];
  const nextStageInfo = nextStage ? STAGES[nextStage] : null;
  const canAdvance = order.status !== 'completed';
  const stageLabel = (id) => (lang === 'ar' && typeof STAGE_LABELS_AR !== 'undefined') ? STAGE_LABELS_AR[id] : STAGES[id].label;

  const InfoRow = ({ label, value, valueColor }) => (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 0' }}>
      <span style={{ fontSize: 14, color: t.label2 }}>{label}</span>
      <span style={{ fontSize: 14, fontWeight: 500, color: valueColor || t.label }}>{value}</span>
    </div>
  );

  return (
    <div style={{ padding: '16px 16px 32px' }}>
      {/* Order header */}
      <div style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 6 }}>
          <div style={{ fontSize: 20, fontWeight: 700, color: t.label, flex: 1 }}>{order.name}</div>
          <StatusPill status={order.status} size="lg" />
        </div>
        <div style={{ fontSize: 13, color: t.label2 }}>{order.customer}</div>
        <div style={{ fontSize: 12, color: t.label3, marginTop: 2 }}>{order.id}</div>
      </div>

      {/* Printing progress */}
      {order.status === 'printing' && order.progress !== undefined && (
        <div style={{
          background: t.surface2, borderRadius: 14,
          padding: '14px', marginBottom: 16,
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <span style={{ fontSize: 13, fontWeight: 600, color: t.label }}>{s('printProgress')}</span>
            <span style={{ fontSize: 22, fontWeight: 700, color: stage.dot, fontVariantNumeric: 'tabular-nums' }}>{order.progress}%</span>
          </div>
          <ProgressBar value={order.progress} color={stage.dot} height={7} />
          {order.eta && (
            <div style={{ fontSize: 12, color: t.label2, marginTop: 8 }}>ETA: {order.eta} · {order.printer}</div>
          )}
        </div>
      )}

      {/* Status timeline */}
      <div style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 0 }}>
          {STAGE_SEQUENCE.map((stageKey, i) => {
            const info = STAGES[stageKey];
            const done = info.order < stage.order;
            const current = stageKey === order.status;
            const future = info.order > stage.order;
            return (
              <React.Fragment key={stageKey}>
                <div style={{
                  display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4,
                }}>
                  <div style={{
                    width: current ? 14 : 10,
                    height: current ? 14 : 10,
                    borderRadius: '50%',
                    background: done ? info.dot : current ? info.dot : t.surface3,
                    border: current ? `2px solid ${info.dot}` : 'none',
                    boxShadow: current ? `0 0 0 4px ${info.bg}` : 'none',
                    transition: 'all 0.2s',
                    flexShrink: 0,
                  }} />
                  <span style={{
                    fontSize: 9, fontWeight: current ? 700 : 500,
                    color: done || current ? info.dot : t.label3,
                    letterSpacing: 0.3,
                  }}>{stageLabel(stageKey)}</span>
                </div>
                {i < STAGE_SEQUENCE.length - 1 && (
                  <div style={{
                    flex: 1, height: 2, marginBottom: 16,
                    background: done ? STAGES[STAGE_SEQUENCE[i]].dot + '60' : t.surface3,
                  }} />
                )}
              </React.Fragment>
            );
          })}
        </div>
      </div>

      <Divider inset={0} />

      {/* Details */}
      <div style={{ marginTop: 4 }}>
        <InfoRow label={s('dueDate')} value={order.dueDate} valueColor={order.overdue ? '#FF453A' : undefined} />
        <Divider />
        <InfoRow label={s('filament')} value={order.filament} />
        <Divider />
        <InfoRow label={s('printer')} value={order.printer || '—'} />
        {order.qty && <><Divider /><InfoRow label={s('quantity')} value={`×${order.qty}`} /></>}
        {order.notes && <><Divider /><InfoRow label={s('notes')} value={order.notes} /></>}
      </div>

      {/* Advance button */}
      {canAdvance && nextStageInfo && (
        <button onClick={() => { onAdvance(order); onClose(); }} style={{
          width: '100%', marginTop: 20,
          padding: '15px 0',
          background: nextStageInfo.dot,
          border: 'none', borderRadius: 14,
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10,
          cursor: 'pointer',
          boxShadow: `0 4px 16px ${nextStageInfo.dot}40`,
        }}>
          <span style={{ fontSize: 16, fontWeight: 700, color: '#fff' }}>
            {s('moveTo')} {stageLabel(nextStage)}
          </span>
          <svg width="16" height="14" viewBox="0 0 16 14" fill="none">
            <path d="M1 7h12M8 1l6 6-6 6" stroke="#fff" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </button>
      )}
      {order.status === 'completed' && (
        <div style={{
          width: '100%', marginTop: 20, padding: '15px 0',
          background: STAGES.completed.bg, borderRadius: 14,
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
        }}>
          <span style={{ fontSize: 18 }}>✓</span>
          <span style={{ fontSize: 15, fontWeight: 600, color: STAGES.completed.dot }}>{s('orderComplete')}</span>
        </div>
      )}
    </div>
  );
}

// ─── Recent History Row ────────────────────────────────────────────────────────

function RecentRow({ order, isLast }) {
  const { t } = useTheme();
  return (
    <>
      <div style={{ padding: '12px 16px', display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{
          width: 36, height: 36, borderRadius: 10, flexShrink: 0,
          background: STAGES.completed.bg,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 16,
        }}>✓</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 14, fontWeight: 500, color: t.label, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{order.name}</div>
          <div style={{ fontSize: 12, color: t.label2 }}>{order.customer} · {order.id}</div>
        </div>
        <div style={{ fontSize: 12, color: t.label3, textAlign: 'right' }}>
          <div>{order.dueDate}</div>
        </div>
      </div>
      {!isLast && <Divider inset={64} />}
    </>
  );
}

// ─── Orders Screen ────────────────────────────────────────────────────────────

function OrdersScreen({ initialFilter }) {
  const { t, s, lang } = useTheme();
  const { orders, advanceOrder } = useApp();
  const [tab, setTab] = useState('active');
  const [filter, setFilter] = useState(initialFilter || 'all');
  const [detailOrder, setDetailOrder] = useState(null);
  const [sheetOpen, setSheetOpen] = useState(false);

  const openDetail = (order) => { setDetailOrder(order); setSheetOpen(true); };
  const closeDetail = () => setSheetOpen(false);

  const activeOrders = orders.filter(o => o.status !== 'completed');
  const recentOrders = orders.filter(o => o.status === 'completed');

  const stageLabel = (id) => (lang === 'ar' && typeof STAGE_LABELS_AR !== 'undefined') ? STAGE_LABELS_AR[id] : STAGES[id].label;
  const filterOpts = [
    { id: 'all',      label: s('f_all'),         count: activeOrders.length },
    { id: 'pending',  label: stageLabel('pending'),  count: activeOrders.filter(o => o.status === 'pending').length },
    { id: 'printing', label: stageLabel('printing'), count: activeOrders.filter(o => o.status === 'printing').length },
    { id: 'post',     label: stageLabel('post'),     count: activeOrders.filter(o => o.status === 'post').length },
    { id: 'qc',       label: stageLabel('qc'),       count: activeOrders.filter(o => o.status === 'qc').length },
  ];

  const displayed = tab === 'active'
    ? (filter === 'all' ? activeOrders : activeOrders.filter(o => o.status === filter))
    : recentOrders;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', position: 'relative' }}>
      {/* Nav */}
      <LargeNavBar
        title={s('tab_orders')}
        right={<span style={{ fontSize: 22, fontWeight: 300, lineHeight: 1 }}>+</span>}
      />

      {/* Segmented control */}
      <div style={{
        display: 'flex', padding: '8px 16px',
        background: t.navBg, backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        flexShrink: 0, gap: 0,
      }}>
        {[{ id: 'active', label: s('active') }, { id: 'recent', label: s('history') }].map(seg => (
          <button key={seg.id} onClick={() => setTab(seg.id)} style={{
            flex: 1, padding: '7px 0',
            background: tab === seg.id ? t.brand : t.surface2,
            color: tab === seg.id ? '#fff' : t.label2,
            border: 'none', cursor: 'pointer',
            fontSize: 14, fontWeight: 600,
            borderRadius: seg.id === 'active' ? '10px 0 0 10px' : '0 10px 10px 0',
            transition: 'all 0.18s ease',
          }}>{seg.label}</button>
        ))}
      </div>

      {/* Filter chips — active only */}
      {tab === 'active' && (
        <div style={{
          background: t.navBg,
          backdropFilter: 'blur(20px)',
          WebkitBackdropFilter: 'blur(20px)',
          flexShrink: 0,
          borderBottom: `0.5px solid ${t.sep}`,
        }}>
          <FilterChips options={filterOpts} active={filter} onChange={setFilter} />
        </div>
      )}

      {/* List */}
      <ScrollView>
        {displayed.length === 0 ? (
          <EmptyState
            icon={tab === 'active' ? '📋' : '📦'}
            title={tab === 'active' ? s('queueClear') : s('noCompleted')}
            subtitle={tab === 'active' ? s('allCaughtUp') : s('completedAppear')}
          />
        ) : (
          <div style={{ paddingTop: 8 }}>
            <div style={{ background: t.surface, borderRadius: 16, margin: '0 16px', overflow: 'hidden' }}>
              {displayed.map((order, i) =>
                tab === 'active' ? (
                  <OrderRow
                    key={order.id}
                    order={order}
                    onTap={openDetail}
                    onAdvance={advanceOrder}
                    isLast={i === displayed.length - 1}
                  />
                ) : (
                  <RecentRow key={order.id} order={order} isLast={i === displayed.length - 1} />
                )
              )}
            </div>
            <div style={{ height: 24 }} />
          </div>
        )}
      </ScrollView>

      {/* Detail Sheet */}
      <BottomSheet
        visible={sheetOpen}
        onDismiss={closeDetail}
        title={detailOrder?.id}
      >
        <OrderDetailContent
          order={detailOrder}
          onAdvance={advanceOrder}
          onClose={closeDetail}
        />
      </BottomSheet>
    </div>
  );
}

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, { OrdersScreen });
