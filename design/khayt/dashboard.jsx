// dashboard.jsx — Khayt Studio home.
function KpiCard({ k }) {
  const up = k.delta >= 0;
  return (
    <div className="card khayt-kpi">
      <div className="row between" style={{ alignItems: "flex-start" }}>
        <span className="eyebrow">{k.label}</span>
        <span className={"kbadge " + (up ? "delta-up" : "delta-down")}
          style={{ background: up ? "var(--ok-soft)" : "var(--danger-soft)" }}>
          <Icon name={up ? "arrowup" : "arrowdown"} size={12} />
          {Math.abs(k.delta)}{k.key === "orders" ? "" : "%"}
        </span>
      </div>
      <div className="row" style={{ alignItems: "baseline", gap: 5, marginTop: 10 }}>
        <span className="metric" style={{ fontSize: 30, color: "var(--text)" }}>{k.value}</span>
        <span className="mono" style={{ fontSize: 13, color: "var(--text-muted)" }}>{k.unit}</span>
      </div>
      <div style={{ marginTop: 10 }}>
        <Spark data={k.spark} w={220} h={36} color={up ? "var(--accent)" : "var(--danger)"} />
      </div>
    </div>
  );
}

function PrinterTile({ p }) {
  const map = { printing: "var(--ok)", idle: "var(--text-muted)", error: "var(--danger)", maint: "var(--warn)" };
  const label = { printing: "Printing", idle: "Idle", error: "Error", maint: "Maintenance" }[p.status];
  return (
    <div className="card khayt-ptile" style={{ padding: "calc(var(--u)*3.5)" }}>
      <div className="row between">
        <div className="row gap8 grow" style={{ minWidth: 0 }}>
          <Icon name="printer" size={16} style={{ color: "var(--text-dim)" }} />
          <strong style={{ fontSize: 13, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{p.name}</strong>
        </div>
        <span className="pill" style={{ borderColor: "transparent", background: "var(--surface-2)", padding: "3px 8px", flexShrink: 0 }}>
          <span className="dot" style={{ background: map[p.status] }} /> {label}
        </span>
      </div>
      <div className="row between" style={{ marginTop: 12, alignItems: "center" }}>
        <div className="col" style={{ gap: 3, minWidth: 0 }}>
          <span style={{ fontSize: 12, color: p.job ? "var(--text-dim)" : "var(--text-faint)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", maxWidth: 150 }}>
            {p.job || "No active job"}
          </span>
          <span className="mono" style={{ fontSize: 11, color: "var(--text-muted)" }}>
            {p.tech}{p.nozzle != null ? ` · ${p.nozzle}°/${p.bed}°` : ""}{p.eta ? ` · ETA ${p.eta}` : ""}
          </span>
        </div>
        {p.status === "printing"
          ? <Ring value={p.progress} size={46} stroke={5} color="var(--ok)">
              <span className="metric" style={{ fontSize: 11 }}>{p.progress}%</span>
            </Ring>
          : <Ring value={p.status === "error" ? 100 : 0} size={46} stroke={5}
              color={map[p.status]} track="var(--surface-3)">
              <Icon name={p.status === "error" ? "alert" : p.status === "maint" ? "settings" : "pause"} size={15}
                style={{ color: map[p.status] }} />
            </Ring>}
      </div>
    </div>
  );
}

function Dashboard() {
  const d = window.KHAYT;
  const attention = [
    { icon: "alert", color: "var(--danger)", t: "Voron 2.4 stopped — thermal runaway", s: "Order #1039 · 8 min ago", a: "Inspect" },
    { icon: "spool", color: "var(--warn)", t: "PETG White below reorder point", s: "640 g left · threshold 800 g", a: "Draft PO" },
    { icon: "clock", color: "var(--info)", t: "3 orders due today", s: "#1042 · #1040 · #1036", a: "View" },
    { icon: "doc", color: "var(--ok)", t: "Invoice #1032 paid", s: "Tuwaiq Models · SAR 980", a: "Receipt" },
  ];
  const rev = [12, 15, 11, 18, 16, 21, 14, 19, 23, 20, 25, 24];
  const revLabels = ["J","F","M","A","M","J","J","A","S","O","N","D"];

  return (
    <div className="col gap16 fade">
      {/* KPIs */}
      <div className="khayt-grid" style={{ gridTemplateColumns: "repeat(4, 1fr)" }}>
        {d.kpis.map((k) => <KpiCard key={k.key} k={k} />)}
      </div>

      <div className="khayt-grid" style={{ gridTemplateColumns: "1.55fr 1fr" }}>
        {/* Live floor */}
        <div className="card flush">
          <div className="row between" style={{ padding: "16px 18px 12px" }}>
            <div className="row gap8">
              <span className="sec-title">Production floor</span>
              <span className="pill" style={{ background: "var(--ok-soft)", borderColor: "transparent", color: "var(--ok)" }}>
                <span className="khayt-live" /> 3 live
              </span>
            </div>
            <button className="btn ghost sm">Open queue <Icon name="chevright" size={13} /></button>
          </div>
          <hr className="thread" style={{ margin: "0 18px" }} />
          <div style={{ padding: 14, display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            {d.printers.map((p) => <PrinterTile key={p.id} p={p} />)}
          </div>
        </div>

        {/* Needs attention */}
        <div className="card flush">
          <div className="row between" style={{ padding: "16px 18px 12px" }}>
            <span className="sec-title">Needs attention</span>
            <span className="pill">{attention.length}</span>
          </div>
          <hr className="thread" style={{ margin: "0 18px" }} />
          <div className="col">
            {attention.map((a, i) => (
              <div key={i} className="khayt-attn">
                <div className="khayt-attn-ic" style={{ color: a.color, background: `color-mix(in srgb, ${a.color} 14%, transparent)` }}>
                  <Icon name={a.icon} size={16} />
                </div>
                <div className="col grow" style={{ gap: 2, minWidth: 0 }}>
                  <span style={{ fontSize: 13, fontWeight: 600 }}>{a.t}</span>
                  <span style={{ fontSize: 11.5, color: "var(--text-muted)" }}>{a.s}</span>
                </div>
                <button className="btn sm subtle">{a.a}</button>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* Revenue + break-even */}
      <div className="khayt-grid" style={{ gridTemplateColumns: "1.55fr 1fr" }}>
        <div className="card">
          <div className="row between">
            <div className="col" style={{ gap: 2 }}>
              <span className="sec-title">Revenue</span>
              <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Last 12 months · SAR</span>
            </div>
            <div className="seg">
              <button>Week</button><button>Month</button><button className="on">Year</button>
            </div>
          </div>
          <div style={{ marginTop: 16 }}><Bars data={rev} labels={revLabels} h={150} /></div>
        </div>

        <div className="card col gap16">
          <span className="sec-title">Break-even · May</span>
          <div className="row gap16" style={{ alignItems: "center" }}>
            <Ring value={78} size={92} stroke={9} color="var(--accent)">
              <div className="col" style={{ alignItems: "center", lineHeight: 1 }}>
                <span className="metric" style={{ fontSize: 20 }}>78%</span>
                <span style={{ fontSize: 9.5, color: "var(--text-muted)" }}>covered</span>
              </div>
            </Ring>
            <div className="col grow gap10">
              {[
                ["Fixed costs", "9,400", "var(--text-muted)"],
                ["Earned", "7,330", "var(--accent)"],
                ["To break even", "2,070", "var(--warn)"],
              ].map(([l, v, c]) => (
                <div key={l} className="row between">
                  <span className="row gap8" style={{ fontSize: 12.5, color: "var(--text-dim)" }}>
                    <span className="dot" style={{ background: c }} />{l}
                  </span>
                  <span className="metric" style={{ fontSize: 13 }}>{v}</span>
                </div>
              ))}
            </div>
          </div>
          <hr className="thread" />
          <div className="row between">
            <span style={{ fontSize: 12.5, color: "var(--text-dim)" }}>Projected close</span>
            <span className="kbadge delta-up" style={{ background: "var(--ok-soft)" }}>+SAR 4,200 profit</span>
          </div>
        </div>
      </div>
    </div>
  );
}

window.Dashboard = Dashboard;
