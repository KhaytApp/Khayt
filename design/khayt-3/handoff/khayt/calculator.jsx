// calculator.jsx — multi-part quote builder with live cost breakdown.
function Calculator() {
  const d = window.KHAYT;
  const [margin, setMargin] = React.useState(40);
  const [tech, setTech] = React.useState("FDM");
  const cost = d.costBreak.reduce((s, x) => s + x.value, 0);
  const price = cost * (1 + margin / 100);
  const cartTotal = d.cart.reduce((s, c) => s + c.cost * c.qty, 0);

  const F = ({ label, val, unit, ph, wide }) => (
    <div className="field" style={{ gridColumn: wide ? "1 / -1" : "auto" }}>
      <label>{label}</label>
      <div style={{ position: "relative" }}>
        <input className="input mono" defaultValue={val} placeholder={ph} />
        {unit && <span className="khayt-unit">{unit}</span>}
      </div>
    </div>
  );

  return (
    <div className="khayt-grid fade" style={{ gridTemplateColumns: "1.3fr 1fr", alignItems: "start" }}>
      {/* Form */}
      <div className="col gap16">
        <div className="card">
          <div className="row between" style={{ marginBottom: 14 }}>
            <span className="sec-title">1 · Part & material</span>
            <div className="seg">
              {["FDM", "Resin"].map((tk) => (
                <button key={tk} className={tech === tk ? "on" : ""} onClick={() => setTech(tk)}>{tk}</button>
              ))}
            </div>
          </div>
          <div className="khayt-form">
            <div className="field" style={{ gridColumn: "1 / 3" }}>
              <label>Part name</label>
              <input className="input" defaultValue="Gearbox housing v3" />
            </div>
            <div className="field">
              <label>Qty</label>
              <input className="input mono" defaultValue="2" />
            </div>
            <div className="field" style={{ gridColumn: "1 / -1" }}>
              <label>Filament</label>
              <div className="row gap8">
                <span className="khayt-swatch lg" style={{ background: "#1a1a1a" }} />
                <select className="input grow"><option>PLA Black · Polymaker · SAR 75/kg</option><option>PETG White · eSUN</option></select>
              </div>
            </div>
            <F label={`Print weight`} val="148" unit={tech === "FDM" ? "g" : "mL"} />
            <F label="Support / waste" val="12" unit="g" />
            <F label="Print time" val="4.37" unit="hrs" />
          </div>
          <button className="btn subtle sm" style={{ marginTop: 12 }}><Icon name="doc" size={14} /> Parse from G-code / 3MF</button>
        </div>

        <div className="card">
          <span className="sec-title">2 · Machine & power</span>
          <div className="khayt-form" style={{ marginTop: 14 }}>
            <div className="field" style={{ gridColumn: "1 / -1" }}>
              <label>Printer preset</label>
              <select className="input"><option>Prusa CORE One+ · 150 W</option><option>Bambu X1C</option></select>
            </div>
            <F label="Power draw" val="150" unit="W" />
            <F label="Energy tariff" val="0.18" unit="/kWh" />
            <F label="Wear & tear" val="0.75" unit="/hr" />
            <F label="Labour rate" val="40" unit="/hr" />
          </div>
        </div>
      </div>

      {/* Live breakdown */}
      <div className="card khayt-sticky col gap16">
        <div className="row between">
          <span className="sec-title">Live cost breakdown</span>
          <span className="pill"><Icon name="bolt" size={12} style={{ color: "var(--accent)" }} /> live</span>
        </div>

        <div className="row gap16" style={{ alignItems: "center" }}>
          <div style={{ position: "relative" }}>
            <Donut segments={d.costBreak} size={128} stroke={17} />
            <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center" }}>
              <div className="col" style={{ alignItems: "center", lineHeight: 1.05 }}>
                <span style={{ fontSize: 9.5, color: "var(--text-muted)" }}>COST</span>
                <span className="metric" style={{ fontSize: 19 }}>{cost.toFixed(0)}</span>
                <span className="mono" style={{ fontSize: 9, color: "var(--text-muted)" }}>SAR</span>
              </div>
            </div>
          </div>
          <div className="col grow gap8">
            {d.costBreak.map((b) => (
              <div key={b.label} className="row between" style={{ alignItems: "center" }}>
                <span className="row gap8" style={{ fontSize: 12, color: "var(--text-dim)", whiteSpace: "nowrap" }}>
                  <span className="dot" style={{ background: b.color }} /> {b.label}
                </span>
                <span className="metric" style={{ fontSize: 12 }}>{b.value.toFixed(2)}</span>
              </div>
            ))}
          </div>
        </div>

        <hr className="thread" />

        <div className="col gap8">
          <div className="row between">
            <span className="lbl" style={{ fontSize: 12.5 }}>Margin</span>
            <span className="metric" style={{ fontSize: 13, color: "var(--accent)" }}>{margin}%</span>
          </div>
          <input type="range" min="0" max="120" value={margin} onChange={(e) => setMargin(+e.target.value)}
            className="khayt-range" />
        </div>

        <div className="khayt-total">
          <div className="row between">
            <span style={{ fontSize: 12.5, color: "var(--text-dim)" }}>Unit cost</span>
            <span className="metric" style={{ fontSize: 13 }}>SAR {cost.toFixed(2)}</span>
          </div>
          <div className="row between" style={{ marginTop: 6 }}>
            <span style={{ fontSize: 12.5, color: "var(--text-dim)" }}>Profit / unit</span>
            <span className="metric delta-up" style={{ fontSize: 13 }}>+SAR {(price - cost).toFixed(2)}</span>
          </div>
          <hr className="thread" style={{ margin: "10px 0" }} />
          <div className="row between" style={{ alignItems: "baseline" }}>
            <span style={{ fontSize: 13, fontWeight: 650 }}>Price / unit</span>
            <span className="metric" style={{ fontSize: 24, color: "var(--accent)" }}>SAR {price.toFixed(2)}</span>
          </div>
        </div>

        <div className="row gap8">
          <button className="btn primary grow"><Icon name="plus" size={15} /> Add to cart</button>
          <button className="btn subtle"><Icon name="doc" size={15} /></button>
        </div>

        <div className="col gap8">
          <div className="row between">
            <span className="eyebrow">Quote cart · {d.cart.length}</span>
            <span className="metric" style={{ fontSize: 12, color: "var(--text-dim)" }}>SAR {cartTotal.toFixed(2)}</span>
          </div>
          {d.cart.map((c) => (
            <div key={c.id} className="khayt-cartrow">
              <span className="khayt-swatch" style={{ background: c.hex }} />
              <span className="grow" style={{ fontSize: 12.5 }}>{c.name}</span>
              <span className="mono" style={{ fontSize: 11, color: "var(--text-muted)" }}>×{c.qty}</span>
              <span className="metric" style={{ fontSize: 12 }}>{(c.cost * c.qty).toFixed(0)}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

window.Calculator = Calculator;
