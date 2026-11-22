// inventory.jsx — filament & resin stock.
function Inventory() {
  const d = window.KHAYT;
  const totalSpools = d.filaments.reduce((s, f) => s + f.spools, 0);
  const low = d.filaments.filter((f) => f.grams < f.reorder);
  const value = d.filaments.reduce((s, f) => s + (f.grams / 1000) * f.cost, 0);
  const stats = [
    { l: "Total spools", v: totalSpools, u: "", c: "var(--info)" },
    { l: "Stock value", v: value.toFixed(0), u: "SAR", c: "var(--accent)" },
    { l: "Below reorder", v: low.length, u: "items", c: "var(--warn)" },
    { l: "Drying now", v: d.filaments.filter(f=>f.drying).length, u: "", c: "var(--violet)" },
  ];
  return (
    <div className="col gap16 fade">
      <div className="khayt-grid" style={{ gridTemplateColumns: "repeat(4,1fr)" }}>
        {stats.map((s) => (
          <div key={s.l} className="card row between" style={{ alignItems: "center" }}>
            <div className="col" style={{ gap: 4 }}>
              <span className="eyebrow">{s.l}</span>
              <span className="row" style={{ alignItems: "baseline", gap: 4 }}>
                <span className="metric" style={{ fontSize: 24 }}>{s.v}</span>
                <span className="mono" style={{ fontSize: 11, color: "var(--text-muted)" }}>{s.u}</span>
              </span>
            </div>
            <span className="dot" style={{ background: s.c, width: 10, height: 10 }} />
          </div>
        ))}
      </div>

      <div className="card flush">
        <div className="row between" style={{ padding: "14px 18px" }}>
          <span className="sec-title">Filament & resin</span>
          <div className="row gap8">
            <div className="seg"><button className="on">All</button><button>FDM</button><button>Resin</button></div>
            <button className="btn sm primary"><Icon name="plus" size={14} /> Add spool</button>
          </div>
        </div>
        <table className="tbl">
          <thead><tr>
            <th>Material</th><th>Type</th><th style={{ width: 240 }}>Stock level</th><th>Spools</th><th>SAR/kg</th><th></th>
          </tr></thead>
          <tbody>
            {d.filaments.map((f) => {
              const pct = Math.min(100, (f.grams / (f.reorder * 2)) * 100);
              const lowS = f.grams < f.reorder;
              return (
                <tr key={f.id}>
                  <td>
                    <div className="row gap10" style={{ alignItems: "center" }}>
                      <span className="khayt-swatch lg" style={{ background: f.hex }} />
                      <div className="col" style={{ minWidth: 0 }}>
                        <strong style={{ fontSize: 13, whiteSpace: "nowrap" }}>{f.name}</strong>
                        <span style={{ fontSize: 11, color: "var(--text-muted)", whiteSpace: "nowrap" }}>{f.brand}</span>
                      </div>
                      {f.drying && <span className="khayt-due" style={{ color: "var(--violet)", background: "var(--violet-soft)" }}>drying</span>}
                    </div>
                  </td>
                  <td><span className="pill" style={{ padding: "2px 8px" }}>{f.type}</span></td>
                  <td>
                    <div className="row between" style={{ marginBottom: 5 }}>
                      <span className="metric" style={{ fontSize: 12, color: lowS ? "var(--warn)" : "var(--text-dim)" }}>{f.grams} g</span>
                      <span className="mono" style={{ fontSize: 10, color: "var(--text-faint)" }}>reorder {f.reorder}</span>
                    </div>
                    <div className="meter"><i style={{ width: pct + "%", background: lowS ? "var(--warn)" : "var(--ok)" }} /></div>
                  </td>
                  <td><span className="metric" style={{ fontSize: 13 }}>{f.spools}</span></td>
                  <td><span className="metric" style={{ fontSize: 13 }}>{f.cost}</span></td>
                  <td style={{ textAlign: "right" }}>
                    {lowS
                      ? <button className="btn sm" style={{ color: "var(--warn)", borderColor: "var(--warn)" }}>Draft PO</button>
                      : <button className="btn ghost sm icon"><Icon name="more" size={16} /></button>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
window.Inventory = Inventory;
