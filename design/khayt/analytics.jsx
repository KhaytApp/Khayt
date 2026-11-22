// analytics.jsx — revenue, machine P&L, retention.
function Analytics() {
  const d = window.KHAYT;
  const machines = [
    { name: "Bambu X1C · A", profit: 6820, hours: 412, util: 84 },
    { name: "Prusa CORE One", profit: 5240, hours: 388, util: 77 },
    { name: "Saturn 4 Ultra", profit: 4110, hours: 296, util: 71 },
    { name: "Bambu X1C · B", profit: 3380, hours: 240, util: 58 },
    { name: "Voron 2.4", profit: 1290, hours: 132, util: 32 },
  ];
  const maxP = Math.max(...machines.map((m) => m.profit));
  const heat = Array.from({ length: 7 * 12 }, (_, i) => (Math.sin(i * 1.3) + Math.cos(i / 3) + 2) / 4);
  const days = ["S","M","T","W","T","F","S"];
  const stat = [
    { l: "Revenue · YTD", v: "182,400", u: "SAR", dl: +18.2 },
    { l: "Net profit", v: "61,300", u: "SAR", dl: +9.4 },
    { l: "Avg. order value", v: "486", u: "SAR", dl: +4.1 },
    { l: "Repeat rate", v: "63", u: "%", dl: +6.0 },
  ];
  return (
    <div className="col gap16 fade">
      <div className="khayt-grid" style={{ gridTemplateColumns: "repeat(4,1fr)" }}>
        {stat.map((s) => (
          <div key={s.l} className="card col" style={{ gap: 8 }}>
            <span className="eyebrow">{s.l}</span>
            <span className="row" style={{ alignItems: "baseline", gap: 4 }}>
              <span className="metric" style={{ fontSize: 26 }}>{s.v}</span>
              <span className="mono" style={{ fontSize: 11, color: "var(--text-muted)" }}>{s.u}</span>
            </span>
            <span className="kbadge delta-up" style={{ background: "var(--ok-soft)", alignSelf: "flex-start" }}>
              <Icon name="trend" size={12} /> {s.dl}%
            </span>
          </div>
        ))}
      </div>

      <div className="khayt-grid" style={{ gridTemplateColumns: "1fr 1fr" }}>
        <div className="card">
          <span className="sec-title">Machine P&amp;L</span>
          <div className="col gap12" style={{ marginTop: 14 }}>
            {machines.map((m) => (
              <div key={m.name} className="col gap6">
                <div className="row between">
                  <span style={{ fontSize: 12.5, whiteSpace: "nowrap" }}>{m.name}</span>
                  <span className="metric" style={{ fontSize: 12.5, whiteSpace: "nowrap" }}>SAR {m.profit.toLocaleString()}</span>
                </div>
                <div className="row gap10" style={{ alignItems: "center" }}>
                  <div className="meter grow"><i style={{ width: (m.profit / maxP * 100) + "%" }} /></div>
                  <span className="mono" style={{ fontSize: 10.5, color: "var(--text-muted)", width: 78, textAlign: "right" }}>{m.hours}h · {m.util}%</span>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div className="card">
          <div className="row between">
            <span className="sec-title">Production heatmap</span>
            <span style={{ fontSize: 11.5, color: "var(--text-muted)" }}>last 12 weeks</span>
          </div>
          <div className="row gap10" style={{ marginTop: 16, alignItems: "flex-start" }}>
            <div className="col" style={{ gap: 4, paddingTop: 1 }}>
              {days.map((d2, i) => <span key={i} className="mono" style={{ fontSize: 9, color: "var(--text-faint)", height: 16, lineHeight: "16px" }}>{d2}</span>)}
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "repeat(12, 1fr)", gap: 4, flex: 1 }}>
              {heat.map((v, i) => (
                <span key={i} style={{ aspectRatio: "1", borderRadius: 3,
                  background: `hsl(var(--accent-h) var(--accent-s) var(--accent-l) / ${0.12 + v * 0.85})` }} />
              ))}
            </div>
          </div>
          <hr className="thread" style={{ margin: "16px 0 12px" }} />
          <div className="row between">
            <span style={{ fontSize: 12, color: "var(--text-dim)" }}>Busiest: Thursdays · 14:00–20:00</span>
            <span className="row gap4" style={{ fontSize: 10.5, color: "var(--text-muted)", alignItems: "center" }}>
              less {[0.15,0.4,0.65,0.9].map((o,i)=><span key={i} style={{width:10,height:10,borderRadius:2,background:`hsl(var(--accent-h) var(--accent-s) var(--accent-l) / ${o})`}} />)} more
            </span>
          </div>
        </div>
      </div>

      <div className="card flush">
        <div className="row between" style={{ padding: "14px 18px" }}>
          <span className="sec-title">Top clients · revenue</span>
          <button className="btn ghost sm">End-of-day report <Icon name="chevright" size={13} /></button>
        </div>
        <table className="tbl">
          <thead><tr><th>Client</th><th>Orders</th><th>Lifetime value</th><th>Share</th><th>Tier</th></tr></thead>
          <tbody>
            {[...d.clients].sort((a,b)=>b.ltv-a.ltv).map((c) => (
              <tr key={c.id}>
                <td><div className="row gap8" style={{ alignItems: "center" }}><span className="dot" style={{ background: c.color, width: 8, height: 8 }} /><strong style={{ fontSize: 13, whiteSpace: "nowrap" }}>{c.name}</strong></div></td>
                <td><span className="metric" style={{ fontSize: 13 }}>{c.orders}</span></td>
                <td><span className="metric" style={{ fontSize: 13 }}>SAR {c.ltv.toLocaleString()}</span></td>
                <td style={{ width: 160 }}><div className="meter"><i style={{ width: (c.ltv/27800*100)+"%", background: c.color }} /></div></td>
                <td><span className="pill" style={{ padding: "2px 9px" }}>{c.tier}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
window.Analytics = Analytics;
