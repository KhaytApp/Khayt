// alt/shell.jsx — Workshop Ledger shell: masthead, horizontal tab nav (or icon rail), routing.
const { useState, useEffect } = React;

/* ---------- Tweak defaults ---------- */
const ALT_TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "theme": "paper",
  "accent": "safety",
  "nav": "topnav",
  "density": "regular",
  "uiFont": "Archivo",
  "rtl": false,
  "proMode": true
}/*EDITMODE-END*/;

// Accent families to explore — pressroom inks on paper.
const ALT_ACCENTS = {
  safety:      { h: 24,  s: "88%", l: "48%", on: "#fdf8f2", label: "Safety Orange" },
  ultramarine: { h: 224, s: "72%", l: "46%", on: "#f4f6fd", label: "Ultramarine" },
  press:       { h: 152, s: "50%", l: "34%", on: "#f2faf5", label: "Press Green" },
  cyan:        { h: 189, s: "80%", l: "38%", on: "#f0fbfd", label: "Filament Cyan" },
};
const ALT_DENSITY_U = { compact: 3.4, regular: 4, comfy: 4.7 };

/* ---------- Navigation model ---------- */
const ALT_NAV = [
  { group: null, items: [{ id: "dashboard", label: "Dashboard", icon: "dashboard" }] },
  { group: "Production", items: [
    { id: "queue", label: "Queue", icon: "queue", live: true },
    { id: "calculator", label: "Calculator", icon: "calculator" },
    { id: "inventory", label: "Inventory", icon: "inventory" },
    { id: "catalog", label: "Catalog", icon: "cube" },
    { id: "waste", label: "Waste", icon: "waste" },
  ]},
  { group: "Sales", items: [
    { id: "orders", label: "Orders", icon: "orders" },
    { id: "clients", label: "Clients", icon: "clients" },
    { id: "gift", label: "Gift Cards", icon: "gift" },
    { id: "portfolio", label: "Portfolio", icon: "portfolio" },
  ]},
  { group: "Business", items: [
    { id: "analytics", label: "Analytics", icon: "analytics" },
    { id: "expenses", label: "Expenses", icon: "expenses", pro: true },
  ]},
];
const ALT_TITLES = {
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

/* ---------- Masthead ---------- */
function Masthead({ proMode, setProMode }) {
  return (
    <header className="alt-masthead">
      <div className="row gap10">
        <div className="alt-logo"><b>خ</b></div>
        <div className="alt-brand">
          <strong>KHAYT</strong>
          <span className="alt-brandsub">خيط · Production Studio</span>
        </div>
      </div>
      <div className="grow" />
      <div className="alt-search">
        <Icon name="search" size={15} style={{ color: "var(--text-muted)" }} />
        <input placeholder="Search orders, clients, parts…" />
        <kbd>⌘K</kbd>
      </div>
      <button className="alt-pin"><Icon name="pin" size={14} /> Olaya <Icon name="chevdown" size={13} /></button>
      <div className="seg" style={{ height: 34 }}>
        <button className={!proMode ? "on" : ""} onClick={() => setProMode(false)}>Simple</button>
        <button className={proMode ? "on" : ""} onClick={() => setProMode(true)}>Pro</button>
      </div>
      <button className="btn icon subtle alt-bell"><Icon name="bell" size={17} /><span className="alt-bdot" /></button>
      <button className="btn primary"><Icon name="plus" size={16} /> New order</button>
      <div className="alt-user">
        <div className="alt-avatar">SA</div>
        <div className="col" style={{ lineHeight: 1.15 }}>
          <strong style={{ fontSize: 12 }}>Sara</strong>
          <span style={{ fontSize: 10, color: "var(--text-muted)" }}>Admin</span>
        </div>
      </div>
      <button className="alt-lang"><Icon name="globe" size={13} /> EN</button>
    </header>
  );
}

/* ---------- Horizontal tab strip ---------- */
function TabNav({ active, setActive, proMode }) {
  return (
    <nav className="alt-tabs">
      {ALT_NAV.map((sec, i) => (
        <React.Fragment key={i}>
          {sec.group && <span className="alt-tabgroup">{sec.group}</span>}
          {sec.items.filter((it) => !it.pro || proMode).map((it) => (
            <button key={it.id} className={"alt-tab" + (active === it.id ? " on" : "")}
              onClick={() => setActive(it.id)}>
              <Icon name={it.icon} size={15} />
              {it.label}
              {it.live && <span className="alt-live" />}
              {it.pro && <span className="alt-protag">PRO</span>}
            </button>
          ))}
        </React.Fragment>
      ))}
      <span style={{ marginInlineStart: "auto" }} />
      <button className={"alt-tab" + (active === "settings" ? " on" : "")}
        onClick={() => setActive("settings")}>
        <Icon name="settings" size={15} /> Settings
      </button>
    </nav>
  );
}

/* ---------- Icon rail ---------- */
function RailNav({ active, setActive, proMode }) {
  return (
    <aside className="alt-rail">
      {ALT_NAV.map((sec, i) => (
        <React.Fragment key={i}>
          {i > 0 && <hr className="thread" />}
          {sec.items.filter((it) => !it.pro || proMode).map((it) => (
            <button key={it.id} className={"alt-railitem" + (active === it.id ? " on" : "")}
              onClick={() => setActive(it.id)} title={it.label}>
              <Icon name={it.icon} size={18} />
              <span>{it.label}</span>
            </button>
          ))}
        </React.Fragment>
      ))}
      <div className="grow" />
      <hr className="thread" />
      <button className={"alt-railitem" + (active === "settings" ? " on" : "")}
        onClick={() => setActive("settings")} title="Settings">
        <Icon name="settings" size={18} />
        <span>Settings</span>
      </button>
    </aside>
  );
}

/* ---------- Page header ---------- */
function PageHead({ active }) {
  const [title, sub] = ALT_TITLES[active] || ["", ""];
  return (
    <div className="alt-pagehead">
      <h1>{title}</h1>
      <span className="alt-pagesub">{sub}</span>
      <div className="grow" />
      <span className="alt-stamp">Olaya · Riyadh</span>
    </div>
  );
}

/* ---------- Placeholder for not-yet-built screens ---------- */
function AltPlaceholder({ id }) {
  const [title] = ALT_TITLES[id] || [id, ""];
  const icon = (ALT_NAV.flatMap((s) => s.items).find((i) => i.id === id) || { icon: "cube" }).icon;
  return (
    <div className="card fade" style={{ display: "grid", placeItems: "center", minHeight: 420, textAlign: "center" }}>
      <div className="col gap12" style={{ alignItems: "center", maxWidth: 380 }}>
        <div className="khayt-ph-ico"><Icon name={icon} size={26} /></div>
        <h3 style={{ fontSize: 18 }}>{title}</h3>
        <p style={{ color: "var(--text-muted)", margin: 0, fontSize: 13 }}>
          This screen carries over from the ledger system — same masthead, tabs, cards and type.
          Tell me to build it out next and I'll flesh out the full {title.toLowerCase()} workflow.
        </p>
      </div>
    </div>
  );
}

/* ---------- App ---------- */
function App() {
  const [t, setTweak] = useTweaks(ALT_TWEAK_DEFAULTS);
  const [active, setActive] = useState("dashboard");
  const proMode = t.proMode;

  const ac = ALT_ACCENTS[t.accent] || ALT_ACCENTS.safety;
  const rootStyle = {
    "--accent-h": ac.h, "--accent-s": ac.s, "--accent-l": ac.l,
    "--on-accent": ac.on,
    "--u": (ALT_DENSITY_U[t.density] || 4) + "px",
    "--font-ui": t.uiFont === "System"
      ? `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`
      : `"${t.uiFont}", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`,
  };

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", t.theme === "ink" ? "dark" : "light");
    document.documentElement.setAttribute("dir", t.rtl ? "rtl" : "ltr");
    document.documentElement.setAttribute("lang", t.rtl ? "ar" : "en");
  }, [t.theme, t.rtl]);

  if (active === "expenses" && !proMode) setActive("dashboard");

  const SCREENS = {
    dashboard: window.Dashboard, queue: window.Queue, calculator: window.Calculator,
    inventory: window.Inventory, analytics: window.Analytics, clients: window.Clients,
  };
  const Screen = SCREENS[active];
  const rail = t.nav === "rail";

  const main = (
    <main className="alt-main">
      <PageHead active={active} />
      <div className="alt-scroll" key={active}>
        {Screen ? <Screen pro={proMode} t={t} /> : <AltPlaceholder id={active} />}
      </div>
    </main>
  );

  return (
    <>
      <div className="alt-app" style={rootStyle} data-screen-label={(ALT_TITLES[active] || [active])[0]}>
        <Masthead proMode={proMode} setProMode={(v) => setTweak("proMode", v)} />
        {!rail && <TabNav active={active} setActive={setActive} proMode={proMode} />}
        {rail
          ? <div className="alt-body">
              <RailNav active={active} setActive={setActive} proMode={proMode} />
              {main}
            </div>
          : main}
      </div>

      <TweaksPanel>
        <TweakSection label="Direction" />
        <TweakRadio label="Paper" value={t.theme} options={["paper", "ink"]} onChange={(v) => setTweak("theme", v)} />
        <TweakColor label="Accent ink" value={`hsl(${ac.h} ${ac.s} ${ac.l})`}
          options={Object.keys(ALT_ACCENTS).map((k) => `hsl(${ALT_ACCENTS[k].h} ${ALT_ACCENTS[k].s} ${ALT_ACCENTS[k].l})`)}
          onChange={(v) => {
            const k = Object.keys(ALT_ACCENTS).find((kk) => `hsl(${ALT_ACCENTS[kk].h} ${ALT_ACCENTS[kk].s} ${ALT_ACCENTS[kk].l})` === v);
            if (k) setTweak("accent", k);
          }} />
        <TweakSection label="Navigation & layout" />
        <TweakRadio label="Navigation" value={t.nav} options={["topnav", "rail"]} onChange={(v) => setTweak("nav", v)} />
        <TweakRadio label="Density" value={t.density} options={["compact", "regular", "comfy"]} onChange={(v) => setTweak("density", v)} />
        <TweakRadio label="UI font" value={t.uiFont} options={["Archivo", "IBM Plex Sans", "System"]} onChange={(v) => setTweak("uiFont", v)} />
        <TweakSection label="Internationalisation" />
        <TweakToggle label="Arabic RTL layout" value={t.rtl} onChange={(v) => setTweak("rtl", v)} />
        <TweakToggle label="Professional mode" value={t.proMode} onChange={(v) => setTweak("proMode", v)} />
      </TweaksPanel>
    </>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
