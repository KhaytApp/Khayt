// clients.jsx — CRM & loyalty.
function Clients() {
  const d = window.KHAYT;
  const tierColor = { Gold: "var(--warn)", Silver: "#aeb6c4", Bronze: "#c08457", "—": "var(--text-muted)" };
  return (
    <div className="col gap16 fade">
      <div className="row between wrap gap12">
        <div className="seg"><button className="on">All</button><button>VAT</button><button>B2C</button><button>Has balance</button></div>
        <div className="row gap8">
          <button className="btn sm subtle"><Icon name="link" size={14} /> Intake form</button>
          <button className="btn sm primary"><Icon name="plus" size={14} /> New client</button>
        </div>
      </div>

      <div className="khayt-grid" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
        {d.clients.map((c) => (
          <div key={c.id} className="card khayt-client">
            <div className="row between">
              <div className="row gap10 grow" style={{ alignItems: "center", minWidth: 0 }}>
                <span className="khayt-cavatar" style={{ background: `color-mix(in srgb, ${c.color} 22%, var(--surface-2))`, color: c.color }}>
                  {c.name.split(" ").map(w=>w[0]).slice(0,2).join("")}
                </span>
                <div className="col grow" style={{ lineHeight: 1.25, minWidth: 0 }}>
                  <strong style={{ fontSize: 13.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.name}</strong>
                  <span className="row gap6" style={{ alignItems: "center" }}>
                    <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{c.tag}</span>
                    {c.tier !== "—" && <span className="row gap4" style={{ fontSize: 11, color: tierColor[c.tier] }}><span className="dot" style={{ background: tierColor[c.tier], width: 6, height: 6 }} />{c.tier}</span>}
                  </span>
                </div>
              </div>
              <Icon name="more" size={16} style={{ color: "var(--text-muted)" }} />
            </div>
            <hr className="thread" style={{ margin: "13px 0" }} />
            <div className="row between">
              {[["Orders", c.orders, ""], ["Lifetime", c.ltv.toLocaleString(), "SAR"], ["Balance", c.balance.toLocaleString(), "SAR"]].map(([l,v,u],i) => (
                <div key={i} className="col" style={{ gap: 3 }}>
                  <span className="mono" style={{ fontSize: 9.5, color: "var(--text-muted)", letterSpacing: "0.06em" }}>{l.toUpperCase()}</span>
                  <span className="row" style={{ alignItems: "baseline", gap: 3 }}>
                    <span className="metric" style={{ fontSize: 15, color: l === "Balance" && c.balance > 0 ? "var(--warn)" : "var(--text)" }}>{v}</span>
                    {u && <span className="mono" style={{ fontSize: 9, color: "var(--text-faint)" }}>{u}</span>}
                  </span>
                </div>
              ))}
            </div>
            {c.credit > 0 && (
              <div style={{ marginTop: 13 }}>
                <div className="row between" style={{ marginBottom: 5 }}>
                  <span style={{ fontSize: 10.5, color: "var(--text-muted)" }}>Credit used</span>
                  <span className="mono" style={{ fontSize: 10.5, color: "var(--text-dim)" }}>{c.balance} / {c.credit}</span>
                </div>
                <div className="meter"><i style={{ width: (c.balance/c.credit*100)+"%", background: c.balance > c.credit*0.7 ? "var(--danger)" : "var(--accent)" }} /></div>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
window.Clients = Clients;
