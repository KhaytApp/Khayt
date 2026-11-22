// queue.jsx — Kanban production queue (hero screen).
function OrderCard({ o, meta }) {
  const prio = { high: "var(--danger)", med: "var(--warn)", low: "var(--text-muted)" }[o.priority];
  return (
    <div className="khayt-kcard" draggable>
      <div className="row between" style={{ alignItems: "center" }}>
        <span className="mono" style={{ fontSize: 12, fontWeight: 600, color: "var(--text-dim)" }}>{o.id}</span>
        <span className="row gap6" style={{ alignItems: "center" }}>
          <span className="dot" style={{ background: prio, width: 7, height: 7 }} title={o.priority} />
          <Icon name="grip" size={13} style={{ color: "var(--text-faint)" }} />
        </span>
      </div>
      <strong style={{ fontSize: 13.5, marginTop: 2 }}>{o.client}</strong>
      <div className="row gap8" style={{ marginTop: 8, alignItems: "center" }}>
        <span className="khayt-swatch" style={{ background: o.colorHex }} />
        <span className="khayt-cname" style={{ fontSize: 11.5, color: "var(--text-dim)" }}>{o.color}</span>
        <span className="grow" />
        <span className="pill" style={{ padding: "2px 7px", fontSize: 10.5 }}>{o.parts} parts</span>
      </div>
      {o.stage === "printing" && (
        <div style={{ marginTop: 10 }}>
          <div className="row between" style={{ marginBottom: 4 }}>
            <span className="mono" style={{ fontSize: 10, color: "var(--text-muted)" }}>{o.machine}</span>
            <span className="mono" style={{ fontSize: 10, color: "var(--ok)" }}>{o.progress}%</span>
          </div>
          <div className="meter"><i style={{ width: o.progress + "%", background: "var(--ok)" }} /></div>
        </div>
      )}
      <hr className="thread" style={{ margin: "11px 0 9px" }} />
      <div className="row between" style={{ alignItems: "center" }}>
        <span className="row gap6" style={{ fontSize: 11, color: "var(--text-muted)" }}>
          <Icon name="clock" size={12} /> {o.time}
        </span>
        <span className="metric" style={{ fontSize: 12.5 }}>SAR {o.value}</span>
      </div>
      <div className="row gap6" style={{ marginTop: 8 }}>
        <span className="khayt-due" style={{
          color: o.due === "Today" ? "var(--danger)" : "var(--text-dim)",
          background: o.due === "Today" ? "var(--danger-soft)" : "var(--surface-2)" }}>
          <Icon name="clock" size={11} /> {o.due}
        </span>
        {o.machine === "Unassigned" && <span className="khayt-due" style={{ color: "var(--warn)", background: "var(--warn-soft)" }}>Unassigned</span>}
      </div>
    </div>
  );
}

function Queue() {
  const d = window.KHAYT;
  const [filter, setFilter] = React.useState("all");
  const cols = d.stages.map((s) => ({
    id: s, meta: d.stageMeta[s],
    orders: d.orders.filter((o) => o.stage === s),
  }));
  const totalVal = (list) => list.reduce((s, o) => s + o.value, 0);

  return (
    <div className="col gap16 fade" style={{ height: "100%" }}>
      <div className="row between wrap gap12">
        <div className="seg">
          {["all", "FDM", "Resin", "By machine"].map((f) => (
            <button key={f} className={filter === f ? "on" : ""} onClick={() => setFilter(f)}>{f}</button>
          ))}
        </div>
        <div className="row gap8">
          <button className="btn sm subtle"><Icon name="filter" size={14} /> Filters</button>
          <button className="btn sm subtle"><Icon name="check" size={14} /> Shift checklist</button>
          <button className="btn sm primary"><Icon name="plus" size={14} /> Add to queue</button>
        </div>
      </div>

      <div className="khayt-kanban">
        {cols.map((c) => (
          <div key={c.id} className="khayt-kcol">
            <div className="khayt-kcol-head">
              <div className="row gap8" style={{ alignItems: "center" }}>
                <span className="dot" style={{ background: c.meta.color, width: 8, height: 8 }} />
                <strong style={{ fontSize: 13 }}>{c.meta.label}</strong>
                <span className="khayt-kcount">{c.orders.length}</span>
              </div>
              <Icon name="more" size={16} style={{ color: "var(--text-muted)" }} />
            </div>
            <div className="khayt-kbar" style={{ background: c.meta.color }} />
            <div className="khayt-kcol-body">
              {c.orders.map((o) => <OrderCard key={o.id} o={o} meta={c.meta} />)}
              <button className="khayt-kadd"><Icon name="plus" size={14} /> Add order</button>
            </div>
            <div className="khayt-kcol-foot">
              <span style={{ fontSize: 11, color: "var(--text-muted)" }}>{c.orders.length} orders</span>
              <span className="metric" style={{ fontSize: 11.5, color: "var(--text-dim)" }}>SAR {totalVal(c.orders).toLocaleString()}</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

window.Queue = Queue;
