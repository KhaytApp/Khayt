// khayt-inventory.jsx — Inventory list, Spool detail, Add spool flow
// Exports: InventoryScreen

// React hooks come from khayt-i18n.jsx (shared scope).

// ─── Remaining bar helper ──────────────────────────────────────────────────────

function remainingColor(pct) {
  if (pct < 15) return '#FF453A';
  if (pct < 30) return '#FFD60A';
  return '#32D74B';
}

// ─── Spool Row ────────────────────────────────────────────────────────────────

function SpoolRow({ spool, onTap, isLast }) {
  const { t, s } = useTheme();
  const pct = Math.round((spool.weightRemaining / spool.weightTotal) * 100);
  const barColor = remainingColor(pct);

  return (
    <>
      <div onClick={() => onTap(spool)} style={{ padding: '12px 16px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 12 }}>
        {/* Color swatch */}
        <div style={{
          width: 40, height: 40, borderRadius: 12, flexShrink: 0,
          background: spool.colorHex,
          border: `2px solid ${spool.colorHex === '#FFFFFF' || spool.colorHex === '#FEFEFE' ? 'rgba(0,0,0,0.1)' : 'transparent'}`,
          boxShadow: '0 2px 8px rgba(0,0,0,0.2)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
        }}>
          {spool.lowStock && (
            <div style={{
              width: 12, height: 12, borderRadius: '50%',
              background: '#FF453A', border: '2px solid ' + t.surface,
              position: 'absolute', marginTop: -28, marginLeft: 28,
            }} />
          )}
        </div>

        {/* Info */}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
            <span style={{ fontSize: 14, fontWeight: 600, color: t.label, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
              {spool.brand} {spool.material} {spool.color}
            </span>
            {spool.lowStock && (
              <span style={{
                fontSize: 9, fontWeight: 700, color: '#FF453A',
                background: 'rgba(255,69,58,0.15)', padding: '1px 5px', borderRadius: 4,
                flexShrink: 0, letterSpacing: 0.4,
              }}>{s('low')}</span>
            )}
          </div>
          <div style={{ fontSize: 12, color: t.label2, marginBottom: 6 }}>
            {spool.sku}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <ProgressBar value={pct} color={barColor} height={4} style={{ flex: 1 }} />
            <span style={{ fontSize: 11, fontWeight: 600, color: barColor, flexShrink: 0, width: 36, textAlign: 'right' }}>
              {spool.weightRemaining}g
            </span>
          </div>
        </div>

        {/* Chevron */}
        <svg width="7" height="13" viewBox="0 0 7 13" fill="none" style={{ flexShrink: 0 }}>
          <path d="M1 1l5 5.5L1 12" stroke={t.label3} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
      {!isLast && <Divider inset={68} />}
    </>
  );
}

// ─── Spool Detail Screen ──────────────────────────────────────────────────────

function SpoolDetailScreen({ spool, onBack }) {
  const { t, dark, s } = useTheme();
  const pct = Math.round((spool.weightRemaining / spool.weightTotal) * 100);
  const barColor = remainingColor(pct);

  const DetailRow = ({ label, value }) => (
    <>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 16px' }}>
        <span style={{ fontSize: 15, color: t.label2 }}>{label}</span>
        <span style={{ fontSize: 15, fontWeight: 500, color: t.label }}>{value}</span>
      </div>
      <Divider inset={16} />
    </>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <NavBar title={`${spool.brand} ${spool.material}`} back={s('tab_inventory')} onBack={onBack} />

      <ScrollView>
        {/* Hero color block */}
        <div style={{
          margin: '16px 16px 0',
          borderRadius: 20,
          background: spool.colorHex,
          height: 140,
          display: 'flex', alignItems: 'flex-end',
          padding: '14px 16px',
          boxShadow: `0 4px 24px ${spool.colorHex}60`,
        }}>
          <div style={{ flex: 1 }}>
            <div style={{
              fontSize: 22, fontWeight: 700,
              color: parseInt(spool.colorHex.slice(1), 16) > 0xAAAAAA ? '#000' : '#fff',
              textShadow: 'none',
            }}>{spool.color}</div>
            <div style={{
              fontSize: 13,
              color: parseInt(spool.colorHex.slice(1), 16) > 0xAAAAAA ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.7)',
            }}>{spool.brand} · {spool.material}</div>
          </div>
        </div>

        {/* Weight gauge */}
        <div style={{
          margin: '12px 16px 0',
          background: t.surface, borderRadius: 16,
          padding: '16px',
        }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 12 }}>
            <div>
              <span style={{ fontSize: 36, fontWeight: 700, color: barColor, fontVariantNumeric: 'tabular-nums' }}>
                {spool.weightRemaining}
              </span>
              <span style={{ fontSize: 14, color: t.label2, marginLeft: 4 }}>{`g ${s('remaining')}`}</span>
            </div>
            <span style={{ fontSize: 15, fontWeight: 600, color: barColor }}>{pct}%</span>
          </div>
          <ProgressBar value={pct} color={barColor} height={8} />
          <div style={{ fontSize: 12, color: t.label3, marginTop: 8 }}>
            {s('ofTotal')} {spool.weightTotal}g
          </div>
          {spool.lowStock && (
            <div style={{
              marginTop: 10, padding: '8px 12px',
              background: 'rgba(255,69,58,0.12)', borderRadius: 10,
              fontSize: 12, fontWeight: 600, color: '#FF453A',
            }}>
              ⚠ {s('lowStockWarn')}
            </div>
          )}
        </div>

        {/* Details */}
        <div style={{ margin: '12px 16px 0', background: t.surface, borderRadius: 16, overflow: 'hidden' }}>
          <div style={{ padding: '10px 16px 0', fontSize: 12, fontWeight: 600, color: t.label2, letterSpacing: 0.6, textTransform: 'uppercase' }}>{s('spoolInfo')}</div>
          <DetailRow label="SKU" value={spool.sku} />
          <DetailRow label="Lot #" value={spool.lot} />
          <DetailRow label={s('printTemp')} value={spool.printTemp} />
          <DetailRow label={s('bedTemp')} value={spool.bedTemp} />
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 16px' }}>
            <span style={{ fontSize: 15, color: t.label2 }}>Spool ID</span>
            <span style={{ fontSize: 12, fontWeight: 500, color: t.label3 }}>{spool.id}</span>
          </div>
        </div>

        <div style={{ height: 32 }} />
      </ScrollView>
    </div>
  );
}

// ─── Add Spool Flow ────────────────────────────────────────────────────────────

function AddSpoolSheet({ visible, onDismiss, onAdd }) {
  const { t, dark, s } = useTheme();
  const [step, setStep] = useState('method'); // method | camera | nfc | manual
  const [nfcWaiting, setNfcWaiting] = useState(false);
  const [form, setForm] = useState({
    brand: '', material: 'PLA+', color: '', colorHex: '#6366F1',
    weightTotal: '1000', weightRemaining: '1000',
    sku: '', lot: '', printTemp: '', bedTemp: '',
  });

  const reset = () => { setStep('method'); setNfcWaiting(false); };
  const handleDismiss = () => { reset(); onDismiss(); };

  const methodCards = [
    {
      id: 'camera', label: s('scanLabel'), sub: s('photoOcr'),
      icon: (
        <svg width="28" height="24" viewBox="0 0 28 24" fill="none">
          <path d="M10 2H4a2 2 0 00-2 2v16a2 2 0 002 2h20a2 2 0 002-2V8l-4-6H10z" stroke={t.brand} strokeWidth="1.8" strokeLinejoin="round"/>
          <circle cx="14" cy="14" r="5" stroke={t.brand} strokeWidth="1.8"/>
          <circle cx="14" cy="14" r="2.5" fill={t.brandDim}/>
        </svg>
      ),
    },
    {
      id: 'nfc', label: s('nfcTap'), sub: s('tapSpoolTag'),
      icon: (
        <svg width="28" height="28" viewBox="0 0 28 28" fill="none">
          <path d="M6 14a8 8 0 008 8" stroke={t.brand} strokeWidth="1.8" strokeLinecap="round"/>
          <path d="M4 14a10 10 0 0010 10" stroke={t.brand} strokeWidth="1.8" strokeLinecap="round" opacity="0.6"/>
          <path d="M2 14a12 12 0 0012 12" stroke={t.brand} strokeWidth="1.8" strokeLinecap="round" opacity="0.3"/>
          <path d="M14 6a8 8 0 010 16" stroke={t.brand} strokeWidth="1.8" strokeLinecap="round"/>
          <circle cx="14" cy="14" r="2.5" fill={t.brand}/>
        </svg>
      ),
    },
    {
      id: 'manual', label: s('manualEntry'), sub: s('typeDetails'),
      icon: (
        <svg width="28" height="28" viewBox="0 0 28 28" fill="none">
          <rect x="4" y="4" width="20" height="20" rx="4" stroke={t.brand} strokeWidth="1.8"/>
          <path d="M9 11h10M9 15h7M9 19h5" stroke={t.brand} strokeWidth="1.8" strokeLinecap="round"/>
        </svg>
      ),
    },
  ];

  const MATERIALS = ['PLA', 'PLA+', 'PLA Matte', 'PETG', 'ABS', 'ASA', 'TPU', 'Nylon', 'PA-CF'];
  const PRESET_COLORS = [
    { label: 'Black', hex: '#1A1A1A' }, { label: 'White', hex: '#F5F5F0' },
    { label: 'Grey', hex: '#8A8A8A' }, { label: 'Red', hex: '#D13131' },
    { label: 'Blue', hex: '#2563EB' }, { label: 'Green', hex: '#16A34A' },
    { label: 'Orange', hex: '#EA580C' }, { label: 'Yellow', hex: '#CA8A04' },
    { label: 'Purple', hex: '#7C3AED' }, { label: 'Cyan', hex: '#0891B2' },
  ];

  const inputStyle = {
    width: '100%', padding: '11px 14px',
    background: t.surface2, border: `1.5px solid ${t.sep}`,
    borderRadius: 12, fontSize: 15, color: t.label,
    outline: 'none', boxSizing: 'border-box',
  };

  const sheetTitle = step === 'method' ? s('addSpool')
    : step === 'camera' ? s('scanLabel')
    : step === 'nfc' ? s('nfcTap')
    : s('manualEntry');

  return (
    <BottomSheet visible={visible} onDismiss={handleDismiss} title={sheetTitle} minHeight={360}>

      {/* Method picker */}
      {step === 'method' && (
        <div style={{ padding: '16px 16px 32px', display: 'flex', flexDirection: 'column', gap: 10 }}>
          {methodCards.map(m => (
            <button key={m.id} onClick={() => { setStep(m.id); if (m.id === 'nfc') setNfcWaiting(true); }} style={{
              display: 'flex', alignItems: 'center', gap: 16,
              padding: '16px', background: t.surface2,
              border: `1.5px solid ${t.sep}`, borderRadius: 16,
              cursor: 'pointer', width: '100%', textAlign: 'left',
            }}>
              <div style={{
                width: 52, height: 52, borderRadius: 14,
                background: t.brandDim,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                flexShrink: 0,
              }}>{m.icon}</div>
              <div>
                <div style={{ fontSize: 16, fontWeight: 600, color: t.label }}>{m.label}</div>
                <div style={{ fontSize: 13, color: t.label2, marginTop: 2 }}>{m.sub}</div>
              </div>
              <svg width="7" height="13" viewBox="0 0 7 13" fill="none" style={{ marginLeft: 'auto', flexShrink: 0 }}>
                <path d="M1 1l5 5.5L1 12" stroke={t.label3} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </button>
          ))}
        </div>
      )}

      {/* Camera mode */}
      {step === 'camera' && (
        <div style={{ padding: '0 16px 32px' }}>
          <div style={{
            background: '#000', borderRadius: 20, overflow: 'hidden',
            height: 220, position: 'relative', marginBottom: 16,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            {/* Simulated live view */}
            <div style={{
              position: 'absolute', inset: 0,
              background: 'linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%)',
            }} />
            <div style={{
              position: 'absolute',
              width: '70%', height: '55%',
              border: '2px solid rgba(129,131,255,0.8)',
              borderRadius: 12,
              boxShadow: '0 0 0 2000px rgba(0,0,0,0.5)',
            }} />
            <div style={{ position: 'relative', zIndex: 1, textAlign: 'center' }}>
              <div style={{ fontSize: 13, color: 'rgba(255,255,255,0.7)', marginTop: 100 }}>
                {s('alignLabel')}
              </div>
            </div>
            {/* Corner guides */}
            {[[0,0],[1,0],[0,1],[1,1]].map(([r,c],i) => (
              <div key={i} style={{
                position: 'absolute',
                top: r === 0 ? '23%' : '62%',
                left: c === 0 ? '15%' : '77%',
                width: 16, height: 16,
                borderTop: r === 0 ? '2.5px solid #8183FF' : 'none',
                borderBottom: r === 1 ? '2.5px solid #8183FF' : 'none',
                borderLeft: c === 0 ? '2.5px solid #8183FF' : 'none',
                borderRight: c === 1 ? '2.5px solid #8183FF' : 'none',
                borderRadius: r === 0 && c === 0 ? '4px 0 0 0' : r === 0 ? '0 4px 0 0' : c === 0 ? '0 0 0 4px' : '0 0 4px 0',
              }} />
            ))}
          </div>
          <button style={{
            width: '100%', padding: '15px',
            background: t.brand, border: 'none',
            borderRadius: 14, fontSize: 16, fontWeight: 700, color: '#fff',
            cursor: 'pointer',
          }} onClick={() => {
            // Simulate scan result → pre-fill and go to manual
            setForm(f => ({ ...f, brand: 'eSUN', material: 'PLA+', color: 'Black', colorHex: '#1A1A1A', sku: 'ESUN-PLA+-BK-1KG', printTemp: '210-230°C', bedTemp: '60-80°C' }));
            setStep('manual');
          }}>
            {s('captureLabel')}
          </button>
          <button onClick={() => setStep('method')} style={{
            width: '100%', marginTop: 10, padding: '12px',
            background: 'none', border: 'none',
            fontSize: 15, color: t.label2, cursor: 'pointer',
          }}>← {s('back')}</button>
        </div>
      )}

      {/* NFC mode */}
      {step === 'nfc' && (
        <div style={{ padding: '24px 16px 32px', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16 }}>
          <div style={{ position: 'relative', width: 120, height: 120 }}>
            {[1,2,3].map(i => (
              <div key={i} style={{
                position: 'absolute',
                inset: -(i * 16),
                borderRadius: '50%',
                border: `1.5px solid ${t.brand}`,
                opacity: 0.3 / i,
                animation: `khayt-nfc-ping ${1 + i * 0.4}s ease-out ${i * 0.3}s infinite`,
              }} />
            ))}
            <div style={{
              width: 120, height: 120, borderRadius: '50%',
              background: t.brandDim,
              border: `2px solid ${t.brand}30`,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
              <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
                <path d="M10 24a14 14 0 0014 14" stroke={t.brand} strokeWidth="2.5" strokeLinecap="round"/>
                <path d="M6 24a18 18 0 0018 18" stroke={t.brand} strokeWidth="2.5" strokeLinecap="round" opacity="0.6"/>
                <path d="M2 24a22 22 0 0022 22" stroke={t.brand} strokeWidth="2.5" strokeLinecap="round" opacity="0.3"/>
                <path d="M24 10a14 14 0 010 28" stroke={t.brand} strokeWidth="2.5" strokeLinecap="round"/>
                <circle cx="24" cy="24" r="5" fill={t.brand}/>
              </svg>
            </div>
          </div>
          <div style={{ textAlign: 'center' }}>
            <div style={{ fontSize: 17, fontWeight: 600, color: t.label }}>{s('readyToScan')}</div>
            <div style={{ fontSize: 14, color: t.label2, marginTop: 6 }}>{s('holdNearTag')}</div>
          </div>
          <button onClick={() => {
            setForm(f => ({ ...f, brand: 'Bambu', material: 'PLA Matte', color: 'Grey', colorHex: '#8A8A8A', sku: 'BL-PLA-M-GY', printTemp: '190-220°C', bedTemp: '35-45°C' }));
            setStep('manual');
          }} style={{
            padding: '12px 28px', background: t.surface2,
            border: `1.5px solid ${t.sep}`, borderRadius: 14,
            fontSize: 14, color: t.label2, cursor: 'pointer',
          }}>{s('simulateNfc')}</button>
          <button onClick={() => setStep('method')} style={{
            background: 'none', border: 'none', fontSize: 15, color: t.label2, cursor: 'pointer',
          }}>← {s('back')}</button>
        </div>
      )}

      {/* Manual form */}
      {step === 'manual' && (
        <div style={{ padding: '16px 16px 32px', display: 'flex', flexDirection: 'column', gap: 12 }}>
          <div style={{ display: 'flex', gap: 10 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, marginBottom: 5, letterSpacing: 0.4 }}>{s('brand')}</div>
              <input style={inputStyle} value={form.brand} placeholder="e.g. eSUN" onChange={e => setForm(f => ({ ...f, brand: e.target.value }))} />
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, marginBottom: 5, letterSpacing: 0.4 }}>{s('material')}</div>
              <select style={{ ...inputStyle, appearance: 'none' }} value={form.material} onChange={e => setForm(f => ({ ...f, material: e.target.value }))}>
                {MATERIALS.map(m => <option key={m}>{m}</option>)}
              </select>
            </div>
          </div>

          <div>
            <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, marginBottom: 8, letterSpacing: 0.4 }}>{s('color')}</div>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {PRESET_COLORS.map(c => (
                <button key={c.hex} onClick={() => setForm(f => ({ ...f, color: c.label, colorHex: c.hex }))} style={{
                  width: 32, height: 32, borderRadius: 10,
                  background: c.hex,
                  border: `2.5px solid ${form.colorHex === c.hex ? t.brand : 'transparent'}`,
                  cursor: 'pointer', flexShrink: 0,
                }} title={c.label} />
              ))}
            </div>
          </div>

          <div style={{ display: 'flex', gap: 10 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, marginBottom: 5, letterSpacing: 0.4 }}>{s('printTemp')}</div>
              <input style={inputStyle} value={form.printTemp} placeholder="210-230°C" onChange={e => setForm(f => ({ ...f, printTemp: e.target.value }))} />
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, marginBottom: 5, letterSpacing: 0.4 }}>{s('bedTemp')}</div>
              <input style={inputStyle} value={form.bedTemp} placeholder="60-80°C" onChange={e => setForm(f => ({ ...f, bedTemp: e.target.value }))} />
            </div>
          </div>

          <div>
            <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, marginBottom: 5, letterSpacing: 0.4 }}>{s('weightRemaining')}</div>
            <input style={inputStyle} type="number" value={form.weightRemaining} onChange={e => setForm(f => ({ ...f, weightRemaining: e.target.value }))} />
          </div>

          <button onClick={() => {
            onAdd({
              id: `SP-${Date.now()}`, ...form,
              weightTotal: parseInt(form.weightTotal) || 1000,
              weightRemaining: parseInt(form.weightRemaining) || 1000,
              lowStock: (parseInt(form.weightRemaining) || 1000) < 200,
            });
            handleDismiss();
          }} style={{
            width: '100%', marginTop: 4,
            padding: '15px', background: t.brand,
            border: 'none', borderRadius: 14,
            fontSize: 16, fontWeight: 700, color: '#fff', cursor: 'pointer',
          }}>{s('addSpool')}</button>
          <button onClick={() => setStep('method')} style={{
            background: 'none', border: 'none', fontSize: 15, color: t.label2, cursor: 'pointer', padding: '4px',
          }}>← {s('back')}</button>
        </div>
      )}
    </BottomSheet>
  );
}

// ─── Inventory Screen ─────────────────────────────────────────────────────────

function InventoryScreen() {
  const { t, s } = useTheme();
  const { spools, addSpool } = useApp();
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('all');
  const [detailSpool, setDetailSpool] = useState(null);
  const [addOpen, setAddOpen] = useState(false);

  const filtered = spools.filter(sp => {
    const matchSearch = !search || `${sp.brand} ${sp.material} ${sp.color} ${sp.sku}`.toLowerCase().includes(search.toLowerCase());
    const matchFilter = filter === 'all' || (filter === 'low' && sp.lowStock);
    return matchSearch && matchFilter;
  });

  if (detailSpool) {
    return <SpoolDetailScreen spool={detailSpool} onBack={() => setDetailSpool(null)} />;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', position: 'relative' }}>
      {/* Nav */}
      <LargeNavBar
        title={s('tab_inventory')}
        right={<span style={{ fontSize: 22, fontWeight: 300, lineHeight: 1 }}>+</span>}
        onRight={() => setAddOpen(true)}
      />

      {/* Search + filters */}
      <div style={{
        flexShrink: 0, padding: '8px 16px',
        background: t.navBg, backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        borderBottom: `0.5px solid ${t.sep}`,
      }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: t.surface2, borderRadius: 12,
          padding: '9px 14px', marginBottom: 8,
        }}>
          <svg width="15" height="15" viewBox="0 0 15 15" fill="none">
            <circle cx="6.5" cy="6.5" r="5" stroke={t.label3} strokeWidth="1.6"/>
            <path d="M10 10l3.5 3.5" stroke={t.label3} strokeWidth="1.6" strokeLinecap="round"/>
          </svg>
          <input
            value={search}
            onChange={e => setSearch(e.target.value)}
            placeholder={s('searchPlaceholder')}
            style={{
              flex: 1, background: 'none', border: 'none', outline: 'none',
              fontSize: 15, color: t.label,
            }}
          />
          {search && (
            <button onClick={() => setSearch('')} style={{ background: 'none', border: 'none', cursor: 'pointer', color: t.label3, fontSize: 16 }}>✕</button>
          )}
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          {[
            { id: 'all', label: `${s('f_all')} (${spools.length})` },
            { id: 'low', label: `${s('lowStockFilter')} (${spools.filter(sp => sp.lowStock).length})` },
          ].map(opt => (
            <button key={opt.id} onClick={() => setFilter(opt.id)} style={{
              padding: '5px 12px', borderRadius: 100,
              background: filter === opt.id ? t.brandDim : t.surface2,
              border: `1.5px solid ${filter === opt.id ? t.brand + '50' : t.sep}`,
              color: filter === opt.id ? t.brand : t.label2,
              fontSize: 12, fontWeight: 600, cursor: 'pointer',
              transition: 'all 0.18s',
            }}>{opt.label}</button>
          ))}
        </div>
      </div>

      {/* List */}
      <ScrollView>
        {filtered.length === 0 ? (
          <EmptyState
            icon="📦"
            title={search ? s('noResults') : s('noSpoolsYet')}
            subtitle={search ? s('tryDiffSearch') : s('addFirstSpool')}
            action={!search ? s('addSpool') : undefined}
            onAction={() => setAddOpen(true)}
          />
        ) : (
          <div style={{ paddingTop: 10 }}>
            <div style={{ background: t.surface, borderRadius: 16, margin: '0 16px', overflow: 'hidden' }}>
              {filtered.map((spool, i) => (
                <SpoolRow
                  key={spool.id}
                  spool={spool}
                  onTap={setDetailSpool}
                  isLast={i === filtered.length - 1}
                />
              ))}
            </div>
            <div style={{ height: 24 }} />
          </div>
        )}
      </ScrollView>

      {/* Add spool sheet */}
      <AddSpoolSheet visible={addOpen} onDismiss={() => setAddOpen(false)} onAdd={addSpool} />
    </div>
  );
}

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, { InventoryScreen });
