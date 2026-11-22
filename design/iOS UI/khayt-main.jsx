// khayt-main.jsx — Root App, mock data, context providers, Tweaks
// Exports: mounts the root React app to #root

// React hooks come from khayt-i18n.jsx (shared scope).

// ─── Mock Data ────────────────────────────────────────────────────────────────

const INITIAL_ORDERS = [
  { id: 'KH-0041', name: 'Bracket Set ×4',      customer: 'Ahmed Al-Rashid', filament: 'eSUN PLA+ Black',       status: 'printing',  dueDate: '2026-06-05', progress: 68, printer: 'Bambu X1C #2', eta: '1h 23m', qty: 4, overdue: false, notes: '' },
  { id: 'KH-0042', name: 'Phone Stand',          customer: 'Sara Almutairi',  filament: 'Polymaker PETG White',  status: 'pending',   dueDate: '2026-06-06', progress: 0,  printer: null,           qty: 1, overdue: false, notes: 'White matte finish preferred' },
  { id: 'KH-0043', name: 'Cable Organizer ×10',  customer: 'Faisal Corp',     filament: 'Bambu PLA Matte Grey',  status: 'post',      dueDate: '2026-06-04', progress: 100, printer: 'Bambu P1S #1', qty: 10, overdue: true,  notes: '' },
  { id: 'KH-0044', name: 'Logo Plaque',          customer: 'Nora Design',     filament: 'eSUN PLA+ White',       status: 'qc',        dueDate: '2026-06-04', progress: 100, printer: 'Creality K1', qty: 1, overdue: false, notes: '' },
  { id: 'KH-0040', name: 'Gear Mount ×2',        customer: 'Tech Solutions',  filament: 'PETG Black',            status: 'completed', dueDate: '2026-06-03', progress: 100, printer: 'Bambu X1C #1', qty: 2, overdue: false, notes: '' },
  { id: 'KH-0039', name: 'Wall Bracket',         customer: 'Home Store',      filament: 'PLA White',             status: 'completed', dueDate: '2026-06-02', progress: 100, printer: 'Bambu P1S #1', qty: 3, overdue: false, notes: '' },
];

const INITIAL_SPOOLS = [
  { id: 'SP-001', brand: 'eSUN',      material: 'PLA+',       color: 'Black',   colorHex: '#1A1A1A', weightTotal: 1000, weightRemaining: 340,  sku: 'ESUN-PLA+-BK-1KG',  lot: 'L240301', printTemp: '210-230°C', bedTemp: '60-80°C',   lowStock: true  },
  { id: 'SP-002', brand: 'Polymaker', material: 'PETG',       color: 'White',   colorHex: '#F5F5F0', weightTotal: 1000, weightRemaining: 890,  sku: 'PM-PETG-WH-1KG',    lot: 'L240408', printTemp: '230-250°C', bedTemp: '70-90°C',   lowStock: false },
  { id: 'SP-003', brand: 'Bambu',     material: 'PLA Matte',  color: 'Grey',    colorHex: '#8A8A8A', weightTotal: 1000, weightRemaining: 85,   sku: 'BL-PLA-M-GY-1KG',   lot: 'L240412', printTemp: '190-220°C', bedTemp: '35-45°C',   lowStock: true  },
  { id: 'SP-004', brand: 'eSUN',      material: 'PLA+',       color: 'White',   colorHex: '#FEFEFE', weightTotal: 1000, weightRemaining: 620,  sku: 'ESUN-PLA+-WH-1KG',  lot: 'L240315', printTemp: '210-230°C', bedTemp: '60-80°C',   lowStock: false },
  { id: 'SP-005', brand: 'Bambu',     material: 'PLA',        color: 'Red',     colorHex: '#C0392B', weightTotal: 1000, weightRemaining: 420,  sku: 'BL-PLA-RD-1KG',     lot: 'L240420', printTemp: '190-220°C', bedTemp: '35-45°C',   lowStock: false },
  { id: 'SP-006', brand: 'Creality',  material: 'PETG',       color: 'Black',   colorHex: '#0A0A0A', weightTotal: 1000, weightRemaining: 155,  sku: 'CR-PETG-BK-1KG',    lot: 'L240320', printTemp: '230-245°C', bedTemp: '70-85°C',   lowStock: true  },
];

const INITIAL_MACHINES = [
  { id: 'M-001', name: 'Bambu X1C #1',  model: 'Bambu Lab X1C', status: 'idle',     material: null,           progress: 0,  eta: null,       currentJob: null,       error: null },
  { id: 'M-002', name: 'Bambu X1C #2',  model: 'Bambu Lab X1C', status: 'printing', material: 'PLA+ Black',   progress: 68, eta: '1h 23m',  currentJob: 'KH-0041',  error: null },
  { id: 'M-003', name: 'Bambu P1S #1',  model: 'Bambu Lab P1S', status: 'idle',     material: null,           progress: 0,  eta: null,       currentJob: null,       error: null },
  { id: 'M-004', name: 'Creality K1',   model: 'Creality K1',   status: 'error',    material: null,           progress: 0,  eta: null,       currentJob: null,       error: 'Nozzle jam — manual clear needed' },
  { id: 'M-005', name: 'Bambu A1 Mini', model: 'Bambu Lab A1 Mini', status: 'idle', material: null,           progress: 0,  eta: null,       currentJob: null,       error: null },
];

const INITIAL_SETTINGS = { host: '192.168.1.42', port: '8765', pin: '5829' };

// ─── TWEAK_DEFAULTS ────────────────────────────────────────────────────────────
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "dark": true,
  "connected": true,
  "showPairing": false,
  "lang": "en",
  "accent": "#8183FF"
}/*EDITMODE-END*/;

// ─── Main App ─────────────────────────────────────────────────────────────────

function KhaytApp() {
  const [tweaks, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const dark = tweaks.dark;
  const t = dark ? DARK_TOKENS : LIGHT_TOKENS;
  const lang = tweaks.lang || 'en';
  const rtl = lang === 'ar';
  const s = useMemo(() => makeS(lang), [lang]);

  const [orders, setOrders] = useState(INITIAL_ORDERS);
  const [spools, setSpools] = useState(INITIAL_SPOOLS);
  const [machines] = useState(INITIAL_MACHINES);
  const [settings, setSettings] = useState(INITIAL_SETTINGS);
  const [connected, setConnected] = useState(tweaks.connected);
  const [showPairing, setShowPairing] = useState(tweaks.showPairing);

  const [activeTab, setActiveTab] = useState('home');
  const [ordersFilter, setOrdersFilter] = useState(null);
  const [showWidget, setShowWidget] = useState(false);

  // Keep connected in sync with tweak (one-way init)
  const [syncDone, setSyncDone] = useState(false);
  React.useEffect(() => {
    if (!syncDone) { setConnected(tweaks.connected); setShowPairing(tweaks.showPairing); setSyncDone(true); }
  }, [tweaks.connected, tweaks.showPairing]);

  const advanceOrder = useCallback((order) => {
    const idx = STAGE_SEQUENCE.indexOf(order.status);
    if (idx >= STAGE_SEQUENCE.length - 1) return;
    const nextStatus = STAGE_SEQUENCE[idx + 1];
    setOrders(prev => prev.map(o => o.id === order.id
      ? { ...o, status: nextStatus, progress: nextStatus === 'completed' ? 100 : o.progress }
      : o
    ));
  }, []);

  const addSpool = useCallback((spool) => {
    setSpools(prev => [spool, ...prev]);
  }, []);

  const updateSettings = useCallback((patch) => {
    setSettings(prev => ({ ...prev, ...patch }));
  }, []);

  const appValue = useMemo(() => ({
    orders, spools, machines, settings, connected, setConnected,
    advanceOrder, addSpool, updateSettings,
  }), [orders, spools, machines, settings, connected]);

  const themeValue = useMemo(() => ({ dark, t, lang, rtl, s }), [dark, t, lang, rtl, s]);

  const goToOrders = useCallback((filter) => {
    setOrdersFilter(filter || null);
    setActiveTab('orders');
  }, []);

  const [pendingOrderDetail, setPendingOrderDetail] = useState(null);

  const openOrderDetail = useCallback((order) => {
    setPendingOrderDetail(order);
    setActiveTab('orders');
  }, []);

  const renderScreen = () => {
    switch (activeTab) {
      case 'home':
        return (
          <HomeScreen
            onOrderTap={openOrderDetail}
            onGoToInventory={() => setActiveTab('inventory')}
            onGoToOrders={goToOrders}
          />
        );
      case 'orders':
        return <OrdersScreen initialFilter={ordersFilter} />;
      case 'inventory':
        return <InventoryScreen />;
      case 'machines':
        return <MachinesScreen />;
      case 'settings':
        return <SettingsScreen onShowPairing={() => setShowPairing(true)} />;
      default:
        return null;
    }
  };

  return (
    <ThemeContext.Provider value={themeValue}>
      <AppContext.Provider value={appValue}>
        <div style={{
          minHeight: '100vh',
          background: dark ? '#0A0A0F' : '#D8D8E0',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif",
          WebkitFontSmoothing: 'antialiased',
          padding: '24px 16px',
        }}>
          <IOSDevice dark={dark} width={393} height={852}>
            <div dir={rtl ? 'rtl' : 'ltr'} style={{
              height: '100%',
              display: 'flex', flexDirection: 'column',
              overflow: 'hidden',
              background: dark ? t.bg : t.bg,
              fontFamily: rtl
                ? "'SF Arabic', 'Geeza Pro', -apple-system, BlinkMacSystemFont, sans-serif"
                : "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif",
            }}>
              {/* Status bar spacer — the IOSDevice renders status bar absolutely */}
              <div style={{ height: 62, flexShrink: 0 }} />

              {/* Connection banner */}
              {!connected && (
                <ConnectionBanner onRetry={() => {
                  setTimeout(() => setConnected(true), 800);
                }} />
              )}

              {/* Screen content */}
              <div style={{ flex: 1, overflow: 'hidden', position: 'relative' }}>
                {renderScreen()}
                {showPairing && (
                  <PairingWizard
                    onComplete={() => setShowPairing(false)}
                    onSkip={() => setShowPairing(false)}
                  />
                )}
                {showWidget && (
                  <WidgetPreview onClose={() => setShowWidget(false)} />
                )}
              </div>

              {/* Tab bar */}
              <TabBar activeTab={activeTab} onTabChange={(tab) => { setActiveTab(tab); setOrdersFilter(null); }} />
            </div>
          </IOSDevice>

          {/* Tweaks panel */}
          <TweaksPanel>
            <TweakSection label="Appearance" />
            <TweakToggle label="Dark mode" value={dark} onChange={v => setTweak('dark', v)} />
            <TweakRadio label="Language" value={lang}
              options={[{ value: 'en', label: 'English' }, { value: 'ar', label: 'العربية' }]}
              onChange={v => setTweak('lang', v)} />
            <TweakSection label="Connection" />
            <TweakToggle label="Connected to desktop" value={connected} onChange={v => setConnected(v)} />
            <TweakSection label="Flows" />
            <TweakButton label="Show Pairing Wizard" onClick={() => setShowPairing(true)} />
            <TweakButton label="Show Home Widgets" onClick={() => setShowWidget(true)} />
            <TweakButton label="Reset all orders" onClick={() => setOrders(INITIAL_ORDERS)} />
          </TweaksPanel>
        </div>
      </AppContext.Provider>
    </ThemeContext.Provider>
  );
}

// ─── Mount ────────────────────────────────────────────────────────────────────
const khaytRoot = ReactDOM.createRoot(document.getElementById('root'));
khaytRoot.render(<KhaytApp />);
