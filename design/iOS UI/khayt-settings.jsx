// khayt-settings.jsx — Settings screen + Pairing wizard
// Exports: SettingsScreen, PairingWizard

// React hooks come from khayt-i18n.jsx (shared scope).

// ─── Setting Row ──────────────────────────────────────────────────────────────

function SettingRow({ label, value, detail, onPress, danger, icon, toggle, onToggle, isLast }) {
  const { t } = useTheme();
  return (
    <>
      <div
        onClick={onPress}
        style={{
          display: 'flex', alignItems: 'center', gap: 12,
          padding: '13px 16px', cursor: onPress ? 'pointer' : undefined,
          minHeight: 50,
        }}
      >
        {icon && (
          <div style={{
            width: 32, height: 32, borderRadius: 9, flexShrink: 0,
            background: danger ? 'rgba(255,69,58,0.14)' : t.brandDim,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>{icon}</div>
        )}
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 15, color: danger ? '#FF453A' : t.label, fontWeight: 500 }}>{label}</div>
          {detail && <div style={{ fontSize: 12, color: t.label2, marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{detail}</div>}
        </div>
        {value && <span style={{ fontSize: 14, color: t.label2, flexShrink: 0 }}>{value}</span>}
        {toggle !== undefined && (
          <div
            onClick={e => { e.stopPropagation(); onToggle(!toggle); }}
            style={{
              width: 50, height: 30, borderRadius: 15,
              background: toggle ? t.brand : t.surface3,
              position: 'relative', cursor: 'pointer', flexShrink: 0,
              transition: 'background 0.2s ease',
            }}
          >
            <div style={{
              position: 'absolute', top: 3, left: toggle ? 22 : 3,
              width: 24, height: 24, borderRadius: 12,
              background: '#fff',
              boxShadow: '0 1px 4px rgba(0,0,0,0.3)',
              transition: 'left 0.2s ease',
            }} />
          </div>
        )}
        {onPress && toggle === undefined && (
          <svg width="7" height="13" viewBox="0 0 7 13" fill="none" style={{ flexShrink: 0 }}>
            <path d="M1 1l5 5.5L1 12" stroke={t.label3} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        )}
      </div>
      {!isLast && <Divider inset={icon ? 60 : 16} />}
    </>
  );
}

function SettingsGroup({ header, footer, children }) {
  const { t } = useTheme();
  return (
    <div style={{ marginBottom: 20 }}>
      {header && (
        <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, letterSpacing: 0.6, textTransform: 'uppercase', padding: '0 16px', marginBottom: 6 }}>
          {header}
        </div>
      )}
      <div style={{ background: t.surface, borderRadius: 16, margin: '0 16px', overflow: 'hidden' }}>
        {children}
      </div>
      {footer && (
        <div style={{ fontSize: 12, color: t.label3, padding: '6px 20px 0', lineHeight: 1.5 }}>{footer}</div>
      )}
    </div>
  );
}

// ─── Connection Test Result ────────────────────────────────────────────────────

function TestResult({ state }) {
  const { t, s, lang } = useTheme();
  if (!state) return null;
  const configs = {
    loading: { color: t.brand, label: lang === 'ar' ? 'جارٍ الاختبار…' : 'Testing connection…', icon: '⟳' },
    success: { color: t.success, label: s('connectedToDesktop'), icon: '✓' },
    error:   { color: '#FF453A', label: lang === 'ar' ? 'فشل الاتصال — تحقق من IP والرمز' : 'Connection failed — check IP and PIN', icon: '✕' },
  };
  const c = configs[state] || configs.error;
  return (
    <div style={{
      margin: '8px 16px', padding: '10px 14px', borderRadius: 12,
      background: state === 'loading' ? t.brandDim : state === 'success' ? t.successDim : t.errorDim,
      display: 'flex', alignItems: 'center', gap: 10,
    }}>
      <span style={{ fontSize: 16, color: c.color, animation: state === 'loading' ? 'khayt-spin 1s linear infinite' : 'none', display: 'inline-block' }}>{c.icon}</span>
      <span style={{ fontSize: 13, fontWeight: 500, color: c.color }}>{c.label}</span>
    </div>
  );
}

// ─── Settings Screen ──────────────────────────────────────────────────────────

function SettingsScreen({ onShowPairing }) {
  const { t, s, lang } = useTheme();
  const { settings, updateSettings, connected, setConnected } = useApp();
  const [testState, setTestState] = useState(null);
  const [editingPin, setEditingPin] = useState(false);
  const [pinVal, setPinVal] = useState(settings.pin || '');

  const runTest = () => {
    setTestState('loading');
    setTimeout(() => setTestState(connected ? 'success' : 'error'), 1400);
  };

  const icons = {
    host: (
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <rect x="1" y="4" width="14" height="9" rx="2" stroke={t.brand} strokeWidth="1.4"/>
        <path d="M5 4V3a1 1 0 011-1h4a1 1 0 011 1v1" stroke={t.brand} strokeWidth="1.4"/>
        <circle cx="8" cy="8.5" r="1.5" fill={t.brand}/>
      </svg>
    ),
    port: (
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path d="M2 8h12M8 2v12" stroke={t.brand} strokeWidth="1.5" strokeLinecap="round"/>
        <circle cx="8" cy="8" r="2.5" stroke={t.brand} strokeWidth="1.4"/>
      </svg>
    ),
    pin: (
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <rect x="3" y="7" width="10" height="8" rx="2" stroke={t.brand} strokeWidth="1.4"/>
        <path d="M5 7V5a3 3 0 016 0v2" stroke={t.brand} strokeWidth="1.4"/>
        <circle cx="8" cy="11" r="1.3" fill={t.brand}/>
      </svg>
    ),
    wifi: (
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path d="M2 7a8.5 8.5 0 0112 0" stroke={t.brand} strokeWidth="1.4" strokeLinecap="round"/>
        <path d="M4 10a5 5 0 018 0" stroke={t.brand} strokeWidth="1.4" strokeLinecap="round"/>
        <path d="M6 13a2.5 2.5 0 014 0" stroke={t.brand} strokeWidth="1.4" strokeLinecap="round"/>
        <circle cx="8" cy="14.5" r="1" fill={t.brand}/>
      </svg>
    ),
    unlink: (
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path d="M6 10l-1.5 1.5a2.83 2.83 0 01-4-4L4 4" stroke="#FF453A" strokeWidth="1.4" strokeLinecap="round"/>
        <path d="M10 6l1.5-1.5a2.83 2.83 0 014 4L12 12" stroke="#FF453A" strokeWidth="1.4" strokeLinecap="round"/>
        <path d="M2 2l12 12" stroke="#FF453A" strokeWidth="1.4" strokeLinecap="round"/>
      </svg>
    ),
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <LargeNavBar title={s('tab_settings')} />

      <ScrollView>
        {/* Connection status header */}
        <div style={{
          margin: '14px 16px 0',
          background: connected ? t.successDim : t.errorDim,
          border: `1px solid ${connected ? t.success + '33' : '#FF453A33'}`,
          borderRadius: 14, padding: '12px 14px',
          display: 'flex', alignItems: 'center', gap: 12,
        }}>
          <div style={{
            width: 40, height: 40, borderRadius: 12,
            background: connected ? t.successDim : t.errorDim,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <div style={{
              width: 12, height: 12, borderRadius: '50%',
              background: connected ? t.success : '#FF453A',
              animation: !connected ? 'khayt-pulse 2s ease-in-out infinite' : 'none',
            }} />
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 14, fontWeight: 600, color: connected ? t.success : '#FF453A' }}>
              {connected ? s('connectedToDesktop') : s('notConnected')}
            </div>
            <div style={{ fontSize: 12, color: t.label2, marginTop: 2 }}>
              {connected ? `${settings.host}:${settings.port}` : s('tapTestRetry')}
            </div>
          </div>
        </div>

        <div style={{ height: 14 }} />

        {/* LAN Connection settings */}
        <SettingsGroup header={s('lanConnection')} footer={s('lanFooter')}>
          <SettingRow label={s('desktopIp')} value={settings.host} detail={s('ipDetail')} icon={icons.host}
            onPress={() => { const v = prompt('Desktop IP address', settings.host); if (v) updateSettings({ host: v }); }} />
          <SettingRow label={s('port')} value={settings.port} icon={icons.port}
            onPress={() => { const v = prompt('Port number', settings.port); if (v) updateSettings({ port: v }); }} />
          <SettingRow label={s('lanPin')} value={'•'.repeat(4)} detail={s('pinDetail')} icon={icons.pin} isLast
            onPress={() => { const v = prompt('Enter 4-digit PIN', ''); if (v) updateSettings({ pin: v }); }} />
        </SettingsGroup>

        {/* Test connection */}
        <SettingsGroup>
          <SettingRow
            label={s('testConnection')}
            icon={icons.wifi}
            onPress={runTest}
            isLast
          />
        </SettingsGroup>
        <TestResult state={testState} />

        {/* Simulate connected toggle for demo */}
        <div style={{ margin: '4px 16px 0' }}>
          <div style={{
            background: t.surface, borderRadius: 14,
            padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 12,
          }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14, fontWeight: 600, color: t.label }}>{s('simulateConn')}</div>
              <div style={{ fontSize: 12, color: t.label2, marginTop: 2 }}>{s('demoToggle')}</div>
            </div>
            <div
              onClick={() => setConnected(!connected)}
              style={{
                width: 50, height: 30, borderRadius: 15,
                background: connected ? t.brand : t.surface3,
                position: 'relative', cursor: 'pointer',
                transition: 'background 0.2s ease',
              }}
            >
              <div style={{
                position: 'absolute', top: 3, left: connected ? 22 : 3,
                width: 24, height: 24, borderRadius: 12,
                background: '#fff', boxShadow: '0 1px 4px rgba(0,0,0,0.3)',
                transition: 'left 0.2s ease',
              }} />
            </div>
          </div>
        </div>

        <div style={{ height: 14 }} />

        {/* Pairing */}
        <SettingsGroup header={s('device')}>
          <SettingRow
            label={s('rerunPairing')}
            detail={s('pairDifferent')}
            icon={icons.wifi}
            onPress={onShowPairing}
          />
          <SettingRow
            label={s('unpairDevice')}
            danger
            icon={icons.unlink}
            onPress={() => {
              if (window.confirm("Unpair this phone from the desktop? You'll need to re-pair to reconnect.")) {
                updateSettings({ host: '', port: '8765', pin: '' });
                setConnected(false);
              }
            }}
            isLast
          />
        </SettingsGroup>

        {/* About */}
        <SettingsGroup header={s('about')}>
          <SettingRow label={s('appVersion')} value="1.0.0-beta" />
          <SettingRow label={s('protocol')} value="LAN v1" />
          <SettingRow label={s('language')} value={lang === 'ar' ? 'العربية' : 'English'} isLast />
        </SettingsGroup>

        <div style={{ height: 32 }} />
      </ScrollView>
    </div>
  );
}

// ─── Pairing Wizard ────────────────────────────────────────────────────────────

function PairingWizard({ onComplete, onSkip }) {
  const { t, dark } = useTheme();
  const { updateSettings, setConnected } = useApp();
  const [step, setStep] = useState(0);
  const [host, setHost] = useState('192.168.1.');
  const [port, setPort] = useState('8765');
  const [pin, setPin] = useState(['', '', '', '']);
  const [testing, setTesting] = useState(false);
  const [testOk, setTestOk] = useState(null);

  const pinRefs = [React.useRef(), React.useRef(), React.useRef(), React.useRef()];

  const setDigit = (i, val) => {
    if (!/^\d?$/.test(val)) return;
    const next = [...pin];
    next[i] = val;
    setPin(next);
    if (val && i < 3) pinRefs[i + 1].current?.focus();
  };

  const testConn = () => {
    setTesting(true);
    setTimeout(() => { setTesting(false); setTestOk(true); }, 1600);
  };

  const steps = [
    // Step 0: Welcome
    {
      title: 'Connect to\nKhayt Desktop',
      content: (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20, padding: '20px 0 0' }}>
          {/* Khayt logo mark */}
          <div style={{
            width: 100, height: 100, borderRadius: 28,
            background: `linear-gradient(135deg, ${t.brand}30 0%, ${t.brand}10 100%)`,
            border: `2px solid ${t.brand}30`,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
          }}>
            <svg width="56" height="56" viewBox="0 0 56 56" fill="none">
              <path d="M12 28L28 12L44 28" stroke={t.brand} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
              <path d="M20 44V28h16v16" stroke={t.brand} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"/>
              <rect x="22" y="36" width="12" height="8" rx="2" fill={t.brandDim}/>
            </svg>
          </div>
          <div style={{ textAlign: 'center' }}>
            <div style={{ fontSize: 15, color: t.label2, lineHeight: 1.6 }}>
              Khayt Companion connects over your <strong style={{ color: t.label }}>local Wi-Fi</strong> to the Khayt desktop app.
            </div>
            <div style={{ marginTop: 12, fontSize: 13, color: t.label3, lineHeight: 1.5 }}>
              No cloud. No account. Shop data stays on your network.
            </div>
          </div>
          <div style={{
            background: t.surface2, borderRadius: 14,
            padding: '12px 16px', width: '100%', display: 'flex', flexDirection: 'column', gap: 8,
          }}>
            {[
              'Khayt desktop app is running',
              'Phone is on the same Wi-Fi',
              'LAN PIN is ready on desktop',
            ].map((item, i) => (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <div style={{ width: 20, height: 20, borderRadius: 10, background: t.brandDim, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                  <span style={{ fontSize: 11, color: t.brand, fontWeight: 700 }}>{i + 1}</span>
                </div>
                <span style={{ fontSize: 13, color: t.label2 }}>{item}</span>
              </div>
            ))}
          </div>
        </div>
      ),
      cta: "Let's go →",
    },
    // Step 1: IP + Port
    {
      title: 'Desktop\nAddress',
      content: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14, paddingTop: 8 }}>
          <div style={{ fontSize: 14, color: t.label2, lineHeight: 1.5 }}>
            On the Khayt desktop app, open <strong style={{ color: t.label }}>Settings → Mobile</strong> to find your IP address.
          </div>
          <div>
            <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, letterSpacing: 0.5, marginBottom: 6, textTransform: 'uppercase' }}>Desktop IP Address</div>
            <input
              value={host}
              onChange={e => setHost(e.target.value)}
              placeholder="192.168.1.100"
              style={{
                width: '100%', padding: '13px 14px',
                background: t.surface2, border: `1.5px solid ${t.sep}`,
                borderRadius: 12, fontSize: 17, color: t.label,
                outline: 'none', boxSizing: 'border-box',
                fontVariantNumeric: 'tabular-nums', letterSpacing: 0.5,
              }}
            />
          </div>
          <div>
            <div style={{ fontSize: 12, fontWeight: 600, color: t.label2, letterSpacing: 0.5, marginBottom: 6, textTransform: 'uppercase' }}>Port</div>
            <input
              value={port}
              onChange={e => setPort(e.target.value)}
              placeholder="8765"
              style={{
                width: '100%', padding: '13px 14px',
                background: t.surface2, border: `1.5px solid ${t.sep}`,
                borderRadius: 12, fontSize: 17, color: t.label,
                outline: 'none', boxSizing: 'border-box',
              }}
            />
            <div style={{ fontSize: 12, color: t.label3, marginTop: 5 }}>Default port is 8765</div>
          </div>
        </div>
      ),
      cta: 'Next: Enter PIN →',
    },
    // Step 2: PIN
    {
      title: 'Enter\nLAN PIN',
      content: (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16, alignItems: 'center', paddingTop: 8 }}>
          <div style={{ fontSize: 14, color: t.label2, lineHeight: 1.5, alignSelf: 'stretch' }}>
            Open <strong style={{ color: t.label }}>Khayt desktop → Settings → Mobile</strong> and tap <em>Show PIN</em>.
          </div>
          <div style={{ display: 'flex', gap: 12 }}>
            {pin.map((d, i) => (
              <input
                key={i}
                ref={pinRefs[i]}
                maxLength={1}
                inputMode="numeric"
                value={d}
                onChange={e => setDigit(i, e.target.value)}
                onKeyDown={e => {
                  if (e.key === 'Backspace' && !d && i > 0) pinRefs[i - 1].current?.focus();
                }}
                style={{
                  width: 60, height: 68, textAlign: 'center',
                  fontSize: 28, fontWeight: 700, letterSpacing: 0,
                  background: t.surface2,
                  border: `2px solid ${d ? t.brand + '80' : t.sep}`,
                  borderRadius: 14, color: t.label,
                  outline: 'none',
                  transition: 'border-color 0.2s',
                }}
              />
            ))}
          </div>
          <div style={{ fontSize: 13, color: t.label3 }}>PIN is stored securely in Keychain</div>
        </div>
      ),
      cta: 'Test Connection →',
    },
    // Step 3: Test
    {
      title: 'All set!',
      content: (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20, paddingTop: 16 }}>
          <div style={{
            width: 80, height: 80, borderRadius: '50%',
            background: testOk ? t.successDim : t.brandDim,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 36,
            transition: 'background 0.3s',
          }}>
            {testing ? (
              <div style={{ width: 32, height: 32, borderRadius: '50%', border: `3px solid ${t.brand}`, borderTopColor: 'transparent', animation: 'khayt-spin 0.8s linear infinite' }} />
            ) : testOk ? '✓' : '📡'}
          </div>
          <div style={{ textAlign: 'center' }}>
            <div style={{ fontSize: 17, fontWeight: 600, color: t.label, marginBottom: 6 }}>
              {testing ? 'Connecting…' : testOk ? 'Connected!' : 'Ready to connect'}
            </div>
            <div style={{ fontSize: 14, color: t.label2, lineHeight: 1.5 }}>
              {testOk ? `Paired with Khayt Desktop at ${host}:${port}` : 'Tap the button below to test your connection'}
            </div>
          </div>
          {!testOk && !testing && (
            <button onClick={testConn} style={{
              padding: '12px 28px', borderRadius: 14,
              background: t.brandDim, border: `1.5px solid ${t.brand}40`,
              color: t.brand, fontSize: 14, fontWeight: 600, cursor: 'pointer',
            }}>Test Connection</button>
          )}
        </div>
      ),
      cta: testOk ? 'Open Khayt Companion' : 'Skip for now',
    },
  ];

  const currentStep = steps[step];

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 300,
      background: dark ? t.bg : t.bg,
      display: 'flex', flexDirection: 'column',
    }}>
      {/* Header */}
      <div style={{ paddingTop: 62, padding: '62px 16px 0', flexShrink: 0 }}>
        {/* Step dots */}
        <div style={{ display: 'flex', gap: 6, marginBottom: 24 }}>
          {steps.map((_, i) => (
            <div key={i} style={{
              height: 4, flex: i <= step ? 2 : 1,
              borderRadius: 2,
              background: i <= step ? t.brand : t.surface3,
              transition: 'all 0.3s ease',
            }} />
          ))}
        </div>
        {/* Title */}
        <div style={{
          fontSize: 30, fontWeight: 700, color: t.label,
          letterSpacing: -0.5, lineHeight: 1.2,
          whiteSpace: 'pre-line',
          marginBottom: 20,
        }}>{currentStep.title}</div>
      </div>

      {/* Content */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '0 16px', paddingBottom: 16 }}>
        {currentStep.content}
      </div>

      {/* CTA */}
      <div style={{ padding: '12px 16px 32px', flexShrink: 0 }}>
        <button onClick={() => {
          if (step < steps.length - 1) {
            setStep(s => s + 1);
          } else {
            updateSettings({ host, port, pin: pin.join('') });
            if (testOk) setConnected(true);
            onComplete();
          }
        }} style={{
          width: '100%', padding: '16px',
          background: t.brand, border: 'none',
          borderRadius: 16, fontSize: 16, fontWeight: 700,
          color: '#fff', cursor: 'pointer',
          boxShadow: `0 4px 20px ${t.brand}40`,
        }}>{currentStep.cta}</button>
        {step > 0 && (
          <button onClick={() => setStep(s => s - 1)} style={{
            width: '100%', marginTop: 10, padding: '12px',
            background: 'none', border: 'none',
            fontSize: 15, color: t.label2, cursor: 'pointer',
          }}>← Back</button>
        )}
        {step === 0 && onSkip && (
          <button onClick={onSkip} style={{
            width: '100%', marginTop: 10, padding: '12px',
            background: 'none', border: 'none',
            fontSize: 15, color: t.label2, cursor: 'pointer',
          }}>Skip setup</button>
        )}
      </div>
    </div>
  );
}

// ─── Export ───────────────────────────────────────────────────────────────────
Object.assign(window, { SettingsScreen, PairingWizard });
