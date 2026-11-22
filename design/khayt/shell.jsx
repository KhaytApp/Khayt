// shell.jsx — Khayt Studio window chrome, grouped sidebar nav, top bar, routing.
const { useState, useEffect, useRef } = React;

/* ---------- Tweak defaults ---------- */
const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "dark",
  "accent": "cyan",
  "density": "regular",
  "uiFont": "Hanken Grotesk",
  "navMode": "full",
  "rtl": false,
  "proMode": true
}/*EDITMODE-END*/;

// Accents derived from the Khayt mark — a glowing cyan خ being 3D-printed on near-black.
const ACCENTS = {
  cyan:   { h: 187, s: "76%", l: "53%", label: "Filament Cyan" },
  teal:   { h: 171, s: "58%", l: "45%", label: "Deep Teal" },
  aqua:   { h: 184, s: "66%", l: "64%", label: "Bed-Glow Aqua" },
  sky:    { h: 200, s: "82%", l: "57%", label: "Print Sky" },
  azure:  { h: 213, s: "72%", l: "61%", label: "Azure" },
};
const DENSITY_U = { compact: 3.4, regular: 4, comfy: 4.7 };

/* ---------- Navigation model ---------- */
const NAV = [
  { group: null, items: [{ id: "dashboard", label: "Dashboard", icon: "dashboard" }] },
  { group: "Production", items: [
    { id: "queue", label: "Production Queue", icon: "queue", live: true },
    { id: "calculator", label: "Calculator", icon: "calculator" },
    { id: "inventory", label: "Inventory", icon: "inventory" },
    { id: "catalog", label: "Catalog", icon: "cube" },
    { id: "waste", label: "Waste Log", icon: "waste" },
  ]},
  { group: "Sales", items: [
    { id: "orders", label: "Orders Log", icon: "orders" },
    { id: "clients", label: "Clients", icon: "clients" },
    { id: "gift", label: "Gift Cards", icon: "gift" },
    { id: "portfolio", label: "Portfolio", icon: "portfolio" },
  ]},
  { group: "Business", items: [
    { id: "analytics", label: "Analytics", icon: "analytics" },
    { id: "expenses", label: "Expenses", icon: "expenses", pro: true },
  ]},
];
const TITLES = {
  dashboard: ["Dashboard", "Tuesday · 29 May 2026"],
  queue: ["Production Queue", "6 printers · 18 active orders"],
  calculator: ["Cost Calculator", "Multi-part quote builder"],
  inventory: ["Inventory", "Filament & resin stock"],
  catalog: ["Catalog", "Saved parts & products"],
  waste: ["Waste Log", "Failed prints & scrap"],
  orders: ["Orders Log", "All orders & invoices"],
  clients: ["Clients", "CRM & loyalty"],
  gift: ["Gift Cards", "Store credit & vouchers"],
  portfolio: ["Portfolio", "Showcase gallery"],
  analytics: ["Analytics", "Revenue, machines & P&L"],
  expenses: ["Expenses", "Costs & accounting"],
  settings: ["Settings", "Shop, printers & integrations"],
};

/* ---------- Traffic lights ---------- */
function Traffic() {
  return (
    <div className="row gap8" style={{ paddingInlineStart: 4 }}>
      {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
        <span key={c} style={{ width: 12, height: 12, borderRadius: "50%", background: c,
          boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.2)" }} />
      ))}
    </div>
  );
}

/* ---------- Sidebar ---------- */
function Sidebar({ active, setActive, navMode, proMode }) {
  const rail = navMode === "rail";
  return (
    <aside className="khayt-sidebar" style={{ width: rail ? 64 : "var(--nav-w)" }}>
      <div className="khayt-brand" style={{ justifyContent: rail ? "center" : "flex-start" }}>
        <div className="khayt-logo"><b>خ</b></div>
        {!rail && (
          <div className="col" style={{ lineHeight: 1.1 }}>
            <strong style={{ fontSize: 15, letterSpacing: "-0.02em" }}>Khayt</strong>
            <span className="mono" style={{ fontSize: 10, color: "var(--text-muted)" }}>خيط · STUDIO</span>
          </div>
        )}
      </div>

      <nav className="khayt-nav">
        {NAV.map((sec, i) => (
          <div key={i} className="khayt-navsec">
            {sec.group && !rail && <div className="eyebrow khayt-navhead">{sec.group}</div>}
            {sec.group && rail && i > 0 && <hr className="thread" style={{ margin: "8px 12px" }} />}
            {sec.items.filter((it) => !it.pro || proMode).map((it) => {
              const on = active === it.id;
              return (
                <button key={it.id} className={"khayt-navitem" + (on ? " on" : "")}
                  onClick={() => setActive(it.id)} title={rail ? it.label : undefined}
                  style={{ justifyContent: rail ? "center" : "flex-start" }}>
                  <Icon name={it.icon} size={18} />
                  {!rail && <span className="grow" style={{ textAlign: "start" }}>{it.label}</span>}
                  {!rail && it.live && <span className="khayt-live" />}
                  {!rail && it.pro && <span className="khayt-pro">PRO</span>}
                </button>
              );
            })}
          </div>
        ))}
      </nav>

      <div className="khayt-navfoot">
        <button className={"khayt-navitem" + (active === "settings" ? " on" : "")}
          onClick={() => setActive("settings")} style={{ justifyContent: rail ? "center" : "flex-start" }}
          title={rail ? "Settings" : undefined}>
          <Icon name="settings" size={18} />
          {!rail && <span>Settings</span>}
        </button>
        {!rail && (
          <div className="khayt-opcard">
            <div className="khayt-avatar">SA</div>
            <div className="col grow" style={{ lineHeight: 1.2, minWidth: 0 }}>
              <strong style={{ fontSize: 12.5 }}>Sara · Admin</strong>
              <span style={{ fontSize: 10.5, color: "var(--text-muted)" }}>Riyadh · Olaya</span>
            </div>
            <Icon name="chevright" size={14} style={{ color: "var(--text-muted)" }} />
          </div>
        )}
      </div>
    </aside>
  );
}

/* ---------- Top bar ---------- */
function TopBar({ active, proMode, setProMode }) {
  const [title, sub] = TITLES[active] || ["", ""];
  return (
    <header className="khayt-top">
      <div className="col khayt-toptitle" style={{ lineHeight: 1.2 }}>
        <h2 style={{ fontSize: 19 }}>{title}</h2>
        <span style={{ fontSize: 12, color: "var(--text-muted)" }}>{sub}</span>
      </div>
      <div className="grow" />
      <div className="khayt-search">
        <Icon name="search" size={15} style={{ color: "var(--text-muted)" }} />
        <input placeholder="Search orders, clients, parts…" />
        <kbd>⌘K</kbd>
      </div>
      <button className="khayt-pin"><Icon name="pin" size={14} /> Olaya <Icon name="chevdown" size={13} /></button>
      <div className="seg" style={{ height: 34 }}>
        <button className={!proMode ? "on" : ""} onClick={() => setProMode(false)}>Simple</button>
        <button className={proMode ? "on" : ""} onClick={() => setProMode(true)}>Pro</button>
      </div>
      <button className="btn icon subtle khayt-bell"><Icon name="bell" size={17} /><span className="khayt-bdot" /></button>
      <button className="btn primary"><Icon name="plus" size={16} /> New order</button>
    </header>
  );
}

/* ---------- Generic placeholder for not-yet-built screens ---------- */
function Placeholder({ id }) {
  const [title, sub] = TITLES[id] || [id, ""];
  return (
    <div className="card fade" style={{ display: "grid", placeItems: "center", minHeight: 420, textAlign: "center" }}>
      <div className="col gap12" style={{ alignItems: "center", maxWidth: 380 }}>
        <div className="khayt-ph-ico"><Icon name={(NAV.flatMap(s=>s.items).find(i=>i.id===id)||{icon:"cube"}).icon} size={26} /></div>
        <h3 style={{ fontSize: 18 }}>{title}</h3>
        <p style={{ color: "var(--text-muted)", margin: 0, fontSize: 13 }}>
          This screen carries over from the redesign system — same sidebar, top bar, cards and type.
          Tell me to build it out next and I'll flesh out the full {title.toLowerCase()} workflow.
        </p>
      </div>
    </div>
  );
}

/* ---------- App ---------- */
function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [active, setActive] = useState("dashboard");
  const proMode = t.proMode;

  // apply theme tokens
  const ac = ACCENTS[t.accent] || ACCENTS.filament;
  const rootStyle = {
    "--accent-h": ac.h, "--accent-s": ac.s, "--accent-l": ac.l,
    "--u": (DENSITY_U[t.density] || 4) + "px",
    "--font-ui": t.uiFont === "System"
      ? `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`
      : `"${t.uiFont}", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`,
  };

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", t.theme);
    document.documentElement.setAttribute("dir", t.rtl ? "rtl" : "ltr");
    document.documentElement.setAttribute("lang", t.rtl ? "ar" : "en");
  }, [t.theme, t.rtl]);

  if (active === "expenses" && !proMode) setActive("dashboard");

  const SCREENS = {
    dashboard: window.Dashboard, queue: window.Queue, calculator: window.Calculator,
    inventory: window.Inventory, analytics: window.Analytics, clients: window.Clients,
  };
  const Screen = SCREENS[active];

  return (
    <div className="khayt-stage">
      <div className="khayt-window" style={rootStyle} data-theme={t.theme}>
        <div className="khayt-titlebar">
          <Traffic />
          <div className="grow row center gap8" style={{ position: "absolute", left: 0, right: 0, pointerEvents: "none" }}>
            <span className="khayt-tbrand"><span className="khayt-tdot" /> Khayt — خيط · Production Studio</span>
          </div>
          <div className="row gap8" style={{ marginInlineStart: "auto", zIndex: 1 }}>
            <button className="khayt-lang"><Icon name="globe" size={14} /> EN</button>
          </div>
        </div>
        <div className="khayt-body">
          <Sidebar active={active} setActive={setActive} navMode={t.navMode} proMode={proMode} />
          <main className="khayt-main">
            <TopBar active={active} proMode={proMode} setProMode={(v) => setTweak("proMode", v)} />
            <div className="khayt-scroll" key={active}>
              {Screen ? <Screen pro={proMode} t={t} /> : <Placeholder id={active} />}
            </div>
          </main>
        </div>
      </div>

      <TweaksPanel>
        <TweakSection label="Theme" />
        <TweakRadio label="Appearance" value={t.theme} options={["dark", "light"]} onChange={(v) => setTweak("theme", v)} />
        <TweakColor label="Accent" value={ACCENTS[t.accent] ? `hsl(${ACCENTS[t.accent].h} ${ACCENTS[t.accent].s} ${ACCENTS[t.accent].l})` : ""}
          options={Object.keys(ACCENTS).map((k) => `hsl(${ACCENTS[k].h} ${ACCENTS[k].s} ${ACCENTS[k].l})`)}
          onChange={(v) => {
            const k = Object.keys(ACCENTS).find((kk) => `hsl(${ACCENTS[kk].h} ${ACCENTS[kk].s} ${ACCENTS[kk].l})` === v);
            if (k) setTweak("accent", k);
          }} />
        <TweakSection label="Layout & density" />
        <TweakRadio label="Density" value={t.density} options={["compact", "regular", "comfy"]} onChange={(v) => setTweak("density", v)} />
        <TweakRadio label="Sidebar" value={t.navMode} options={["full", "rail"]} onChange={(v) => setTweak("navMode", v)} />
        <TweakRadio label="UI font" value={t.uiFont} options={["Hanken Grotesk", "IBM Plex Sans", "System"]} onChange={(v) => setTweak("uiFont", v)} />
        <TweakSection label="Internationalisation" />
        <TweakToggle label="Arabic RTL layout" value={t.rtl} onChange={(v) => setTweak("rtl", v)} />
        <TweakToggle label="Professional mode" value={t.proMode} onChange={(v) => setTweak("proMode", v)} />
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
