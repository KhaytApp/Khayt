// charts.jsx — tiny SVG chart primitives (no deps). Attached to window.

function Spark({ data, w = 120, h = 34, color = "var(--accent)", fill = true, strokeWidth = 1.8 }) {
  const min = Math.min(...data), max = Math.max(...data), span = max - min || 1;
  const step = w / (data.length - 1);
  const pts = data.map((v, i) => [i * step, h - 3 - ((v - min) / span) * (h - 6)]);
  const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
  const area = line + ` L ${w} ${h} L 0 ${h} Z`;
  const id = "g" + Math.random().toString(36).slice(2, 7);
  return (
    <svg width={w} height={h} viewBox={`0 0 ${w} ${h}`} style={{ display: "block", overflow: "visible" }}>
      {fill && (
        <>
          <defs><linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor={color} stopOpacity="0.22" />
            <stop offset="1" stopColor={color} stopOpacity="0" />
          </linearGradient></defs>
          <path d={area} fill={`url(#${id})`} />
        </>
      )}
      <path d={line} fill="none" stroke={color} strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" />
      <circle cx={pts[pts.length - 1][0]} cy={pts[pts.length - 1][1]} r="2.4" fill={color} />
    </svg>
  );
}

function Ring({ value, size = 54, stroke = 6, color = "var(--accent)", track = "var(--surface-3)", children }) {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  return (
    <div style={{ position: "relative", width: size, height: size }}>
      <svg width={size} height={size} style={{ transform: "rotate(-90deg)" }}>
        <circle cx={size/2} cy={size/2} r={r} fill="none" stroke={track} strokeWidth={stroke} />
        <circle cx={size/2} cy={size/2} r={r} fill="none" stroke={color} strokeWidth={stroke}
          strokeDasharray={c} strokeDashoffset={c * (1 - value / 100)} strokeLinecap="round"
          style={{ transition: "stroke-dashoffset .6s ease" }} />
      </svg>
      {children != null && (
        <div style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center" }}>{children}</div>
      )}
    </div>
  );
}

function Donut({ segments, size = 132, stroke = 18 }) {
  const r = (size - stroke) / 2, c = 2 * Math.PI * r;
  let acc = 0;
  const total = segments.reduce((s, x) => s + x.pct, 0) || 100;
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <g transform={`rotate(-90 ${size/2} ${size/2})`}>
        {segments.map((s, i) => {
          const len = (s.pct / total) * c;
          const el = (
            <circle key={i} cx={size/2} cy={size/2} r={r} fill="none" stroke={s.color}
              strokeWidth={stroke} strokeDasharray={`${len} ${c - len}`} strokeDashoffset={-acc} />
          );
          acc += len; return el;
        })}
      </g>
    </svg>
  );
}

function Bars({ data, h = 120, color = "var(--accent)", labels }) {
  const max = Math.max(...data) || 1;
  return (
    <div className="row" style={{ alignItems: "flex-end", gap: 6, height: h }}>
      {data.map((v, i) => (
        <div key={i} className="col grow" style={{ alignItems: "center", gap: 6, height: "100%", justifyContent: "flex-end" }}>
          <div style={{ width: "100%", maxWidth: 26, height: `${(v / max) * 100}%`, minHeight: 3,
            background: i === data.length - 1 ? color : "var(--surface-3)", borderRadius: "4px 4px 2px 2px",
            transition: "height .5s ease" }} />
          {labels && <span className="mono" style={{ fontSize: 9.5, color: "var(--text-muted)" }}>{labels[i]}</span>}
        </div>
      ))}
    </div>
  );
}

Object.assign(window, { Spark, Ring, Donut, Bars });
