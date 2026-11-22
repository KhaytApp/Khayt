// khayt-machines.jsx — Machines screen
// Exports: MachinesScreen

// ─── Machine Card ──────────────────────────────────────────────────────────────

function MachineCard({ machine }) {
  const { t, s } = useTheme();

  const statusConfig = {
    idle:     { label: s('idle'),         color: t.label3,     bg: t.surface3 },
    printing: { label: s('printingStat'), color: STAGES.printing.dot, bg: STAGES.printing.bg },
    error:    { label: s('error'),        color: '#FF453A',    bg: 'rgba(255,69,58,0.14)' },
    offline:  { label: s('offline'),      color: t.label3,     bg: t.surface3 },
  };
  const cfg = statusConfig[machine.status] || statusConfig.offline;

  return (
    <div style={{ padding: '14px 16px', display: 'flex', gap: 14, alignItems: 'flex-start' }}>
      {/* Icon */}
      <div style={{
        width: 46, height: 46, borderRadius: 14, flexShrink: 0,
        background: machine.status === 'printing' ? STAGES.printing.bg : t.surface3,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        border: machine.status === 'error' ? '1.5px solid rgba(255,69,58,0.4)' : 'none',
      }}>
        <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
          <rect x="2" y="7" width="20" height="13" rx="2.5" stroke={cfg.color} strokeWidth="1.7"/>
          <path d="M7 4h10" stroke={cfg.color} strokeWidth="1.7" strokeLinecap="round"/>
          <circle cx="12" cy="13.5" r="2.5" stroke={cfg.color} strokeWidth="1.6"/>
          <path d="M7 13.5h2.5M14.5 13.5H17" stroke={cfg.color} strokeWidth="1.6" strokeLinecap="round"/>
        </svg>
      </div>

      {/* Info */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 3 }}>
          <span style={{ fontSize: 15, fontWeight: 600, color: t.label, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            {machine.name}
          </span>
          {/* Status pill */}
          <span style={{
            display: 'inline-flex', alignItems: 'center', gap: 5,
            padding: '3px 9px', borderRadius: 100,
            background: cfg.bg, fontSize: 11, fontWeight: 600, color: cfg.color,
            flexShrink: 0,
          }}>
            <span style={{
              width: 5, height: 5, borderRadius: '50%', background: cfg.color, flexShrink: 0,
              animation: machine.status === 'printing' ? 'khayt-pulse 2s ease-in-out infinite' : 'none',
            }} />
            {cfg.label}
          </span>
        </div>

        {/* Printing details */}
        {machine.status === 'printing' && (
          <>
            <div style={{ fontSize: 12, color: t.label2, marginBottom: 6 }}>
              {machine.material} · {s('job')} {machine.currentJob}
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <ProgressBar value={machine.progress} color={STAGES.printing.dot} height={4} style={{ flex: 1 }} />
              <span style={{ fontSize: 11, fontWeight: 600, color: STAGES.printing.dot, flexShrink: 0 }}>
                {machine.progress}%
              </span>
            </div>
            {machine.eta && (
              <div style={{ fontSize: 11, color: t.label3, marginTop: 5 }}>ETA: {machine.eta}</div>
            )}
          </>
        )}

        {/* Error state */}
        {machine.status === 'error' && machine.error && (
          <div style={{
            display: 'flex', alignItems: 'center', gap: 6,
            padding: '6px 10px', borderRadius: 9,
            background: 'rgba(255,69,58,0.12)', marginTop: 4,
          }}>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <circle cx="6" cy="6" r="5" stroke="#FF453A" strokeWidth="1.5"/>
              <path d="M6 3.5v3M6 8.5v.5" stroke="#FF453A" strokeWidth="1.5" strokeLinecap="round"/>
            </svg>
            <span style={{ fontSize: 12, color: '#FF453A', fontWeight: 500 }}>{machine.error}</span>
          </div>
        )}

        {/* Idle state */}
        {machine.status === 'idle' && (
          <div style={{ fontSize: 12, color: t.label3, marginTop: 1 }}>{s('readyForJob')}</div>
        )}

        {/* Offline state */}
        {machine.status === 'offline' && (
          <div style={{ fontSize: 12, color: t.label3, marginTop: 1 }}>{s('notConnected')}</div>
        )}
      </div>
    </div>
  );
}

// ─── Machines Summary Bar ─────────────────────────────────────────────────────

function MachinesSummary({ machines }) {
  const { t, s } = useTheme();
  const printing = machines.filter(m => m.status === 'printing').length;
  const idle = machines.filter(m => m.status === 'idle').length;
  const errors = machines.filter(m => m.status === 'error').length;

  return (
    <div style={{ display: 'flex', gap: 10, padding: '14px 16px 0' }}>
      {[
        { label: s('printingStat'), count: printing, color: STAGES.printing.dot, bg: STAGES.printing.bg },
        { label: s('idle'),     count: idle,     color: t.label3,            bg: t.surface3 },
        { label: s('error'),    count: errors,   color: '#FF453A',           bg: 'rgba(255,69,58,0.14)' },
      ].map(item => (
        <div key={item.label} style={{
          flex: 1, background: item.bg,
          borderRadius: 14, padding: '10px 12px',
          display: 'flex', flexDirection: 'column', gap: 3,
        }}>
          <div style={{ fontSize: 22, fontWeight: 700, color: item.color, fontVariantNumeric: 'tabular-nums' }}>
            {item.count}
          </div>
          <div style={{ fontSize: 11, fontWeight: 600, color: item.color, opacity: 0.85 }}>{item.label}</div>
        </div>
      ))}
    </div>
  );
}

// ─── Machines Screen ──────────────────────────────────────────────────────────

function MachinesScreen() {
  const { t, s } = useTheme();
  const { machines } = useApp();

  // Sort: errors first, then printing, then idle, then offline
  const sorted = [...machines].sort((a, b) => {
    const order = { error: 0, printing: 1, idle: 2, offline: 3 };
    return (order[a.status] ?? 4) - (order[b.status] ?? 4);
  });

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <LargeNavBar title={s('tab_machines')} />

      <ScrollView>
        {/* Summary */}
        <MachinesSummary machines={machines} />

        {/* Machine list */}
        <div style={{ marginTop: 16 }}>
          <SectionLabel text={`${machines.length} ${s('printersCount')}`} />
          <div style={{ background: t.surface, borderRadius: 16, margin: '0 16px', overflow: 'hidden' }}>
            {sorted.map((machine, i) => (
              <React.Fragment key={machine.id}>
                <MachineCard machine={machine} />
                {i < sorted.length - 1 && <Divider inset={76} />}
              </React.Fragment>
            ))}
          </div>
        </div>

        <div style={{ height: 24 }} />
      </ScrollView>
    </div>
  );
}

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, { MachinesScreen });
