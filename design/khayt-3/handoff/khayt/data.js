// data.js — mock data for the Khayt Studio redesign prototype.
window.KHAYT = (function () {
  const clients = [
    { id: "c1", name: "Najd Robotics", tag: "VAT", tier: "Gold", color: "#5b9cf0", orders: 34, ltv: 18420, credit: 5000, balance: 1240, currency: "SAR" },
    { id: "c2", name: "Atelier Hessa", tag: "VAT", tier: "Silver", color: "#9a86f5", orders: 12, ltv: 6310, credit: 2000, balance: 0, currency: "SAR" },
    { id: "c3", name: "Khalid M.", tag: "B2C", tier: "—", color: "#3fb87f", orders: 3, ltv: 540, credit: 0, balance: 0, currency: "SAR" },
    { id: "c4", name: "Tuwaiq Models", tag: "VAT", tier: "Gold", color: "#e0a93c", orders: 51, ltv: 27800, credit: 8000, balance: 3100, currency: "SAR" },
    { id: "c5", name: "Reem A.", tag: "B2C", tier: "Bronze", color: "#e5544b", orders: 7, ltv: 1290, credit: 0, balance: 0, currency: "SAR" },
    { id: "c6", name: "Coastal Drones", tag: "VAT", tier: "Silver", color: "#06b6d4", orders: 19, ltv: 9870, credit: 3000, balance: 480, currency: "SAR" },
  ];

  const printers = [
    { id: "p1", name: "Prusa CORE One", tech: "FDM", status: "printing", job: "Najd — gearbox housing", progress: 67, nozzle: 215, bed: 60, eta: "1h 48m", color: "#3fb87f" },
    { id: "p2", name: "Bambu X1C · A", tech: "FDM", status: "printing", job: "Tuwaiq — figurine batch", progress: 23, nozzle: 220, bed: 65, eta: "4h 02m", color: "#3fb87f" },
    { id: "p3", name: "Bambu X1C · B", tech: "FDM", status: "idle", job: null, progress: 0, nozzle: 28, bed: 24, eta: null, color: "#6c7689" },
    { id: "p4", name: "Saturn 4 Ultra", tech: "Resin", status: "printing", job: "Atelier — ring masters", progress: 88, nozzle: null, bed: null, eta: "12m", color: "#3fb87f" },
    { id: "p5", name: "Voron 2.4", tech: "FDM", status: "error", job: "Coastal — drone arm", progress: 41, nozzle: 0, bed: 0, eta: null, color: "#e5544b" },
    { id: "p6", name: "Elegoo Neptune", tech: "FDM", status: "maint", job: null, progress: 0, nozzle: null, bed: null, eta: null, color: "#e0a93c" },
  ];

  // Kanban orders
  const stages = ["pending", "printing", "post", "qc", "done"];
  const orders = [
    { id: "#1042", client: "Najd Robotics", parts: 4, color: "PLA Black", colorHex: "#1a1a1a", machine: "Prusa CORE One", stage: "printing", due: "Today", priority: "high", value: 480, weight: 320, time: "6h 10m", progress: 67 },
    { id: "#1041", client: "Tuwaiq Models", parts: 12, color: "PETG White", colorHex: "#f0f0f0", machine: "Bambu X1C · A", stage: "printing", due: "Tomorrow", priority: "med", value: 1240, weight: 890, time: "14h 30m", progress: 23 },
    { id: "#1040", client: "Atelier Hessa", parts: 6, color: "Resin Grey", colorHex: "#8a8f99", machine: "Saturn 4 Ultra", stage: "printing", due: "Today", priority: "high", value: 720, weight: 140, time: "5h 20m", progress: 88 },
    { id: "#1039", client: "Coastal Drones", parts: 2, color: "ASA Black", colorHex: "#222", machine: "Voron 2.4", stage: "pending", due: "Wed", priority: "med", value: 360, weight: 210, time: "4h 05m", progress: 0 },
    { id: "#1038", client: "Khalid M.", parts: 1, color: "PLA Red", colorHex: "#c0392b", machine: "Unassigned", stage: "pending", due: "Fri", priority: "low", value: 95, weight: 60, time: "1h 40m", progress: 0 },
    { id: "#1037", client: "Reem A.", parts: 3, color: "PLA Silk Gold", colorHex: "#c9a227", machine: "Unassigned", stage: "pending", due: "Fri", priority: "low", value: 210, weight: 130, time: "3h 12m", progress: 0 },
    { id: "#1036", client: "Tuwaiq Models", parts: 8, color: "PETG Black", colorHex: "#1a1a1a", machine: "Bambu X1C · B", stage: "post", due: "Today", priority: "high", value: 640, weight: 410, time: "9h 00m", progress: 100 },
    { id: "#1035", client: "Najd Robotics", parts: 2, color: "TPU Black", colorHex: "#2a2a2a", machine: "Prusa CORE One", stage: "post", due: "Tomorrow", priority: "med", value: 180, weight: 90, time: "3h 30m", progress: 100 },
    { id: "#1034", client: "Atelier Hessa", parts: 5, color: "Resin Clear", colorHex: "#d8e0e8", machine: "Saturn 4 Ultra", stage: "qc", due: "Today", priority: "med", value: 540, weight: 95, time: "4h 10m", progress: 100 },
    { id: "#1033", client: "Coastal Drones", parts: 4, color: "ASA Orange", colorHex: "#e8743b", machine: "Voron 2.4", stage: "qc", due: "Tomorrow", priority: "low", value: 420, weight: 260, time: "6h 45m", progress: 100 },
    { id: "#1032", client: "Tuwaiq Models", parts: 10, color: "PLA White", colorHex: "#f5f5f5", machine: "Bambu X1C · A", stage: "done", due: "Yesterday", priority: "med", value: 980, weight: 720, time: "11h 20m", progress: 100 },
    { id: "#1031", client: "Khalid M.", parts: 1, color: "PLA Blue", colorHex: "#2d6cdf", machine: "Prusa CORE One", stage: "done", due: "Yesterday", priority: "low", value: 110, weight: 70, time: "1h 55m", progress: 100 },
  ];

  const stageMeta = {
    pending: { label: "Pending", color: "var(--text-muted)" },
    printing:{ label: "Printing", color: "var(--info)" },
    post:    { label: "Post-Processing", color: "var(--violet)" },
    qc:      { label: "QC", color: "var(--warn)" },
    done:    { label: "Done", color: "var(--ok)" },
  };

  const filaments = [
    { id: "f1", name: "PLA Black", brand: "Polymaker", type: "FDM", grams: 2840, spools: 3, hex: "#1a1a1a", reorder: 1000, cost: 75, drying: false },
    { id: "f2", name: "PETG White", brand: "eSUN", type: "FDM", grams: 640, spools: 1, hex: "#f0f0f0", reorder: 800, cost: 82, drying: false },
    { id: "f3", name: "PLA Silk Gold", brand: "SUNLU", type: "FDM", grams: 210, spools: 1, hex: "#c9a227", reorder: 500, cost: 95, drying: false },
    { id: "f4", name: "ASA Black", brand: "Prusament", type: "FDM", grams: 1450, spools: 2, hex: "#222", reorder: 600, cost: 110, drying: false },
    { id: "f5", name: "TPU 95A Black", brand: "Polymaker", type: "FDM", grams: 380, spools: 1, hex: "#2a2a2a", reorder: 400, cost: 130, drying: true },
    { id: "f6", name: "Resin Grey 8K", brand: "Siraya Tech", type: "Resin", grams: 1100, spools: 2, hex: "#8a8f99", reorder: 1000, cost: 145, drying: false },
    { id: "f7", name: "Resin Clear", brand: "Anycubic", type: "Resin", grams: 320, spools: 1, hex: "#d8e0e8", reorder: 500, cost: 120, drying: false },
    { id: "f8", name: "PLA White", brand: "Bambu Lab", type: "FDM", grams: 3200, spools: 4, hex: "#f5f5f5", reorder: 1000, cost: 78, drying: false },
  ];

  // dashboard KPIs
  const kpis = [
    { key: "revenue", label: "Revenue · MTD", value: "24,680", unit: "SAR", delta: +12.4, spark: [8,11,9,14,12,17,16,19,18,22,21,25] },
    { key: "orders", label: "Active orders", value: "18", unit: "", delta: +3, spark: [12,13,11,14,15,14,16,15,17,16,18,18] },
    { key: "util", label: "Printer utilisation", value: "73", unit: "%", delta: +5.1, spark: [60,62,58,65,68,64,70,69,72,71,73,73] },
    { key: "margin", label: "Avg. margin", value: "41", unit: "%", delta: -1.8, spark: [44,45,43,46,44,42,43,41,42,40,41,41] },
  ];

  // calculator default cart
  const cart = [
    { id: "k1", name: "Gearbox housing", qty: 2, filament: "PLA Black", hex: "#1a1a1a", grams: 148, time: 4.37, cost: 38.5 },
    { id: "k2", name: "Mounting bracket", qty: 4, filament: "PETG White", hex: "#f0f0f0", grams: 62, time: 1.8, cost: 19.2 },
    { id: "k3", name: "Cable clip", qty: 10, filament: "TPU 95A Black", hex: "#2a2a2a", grams: 8, time: 0.4, cost: 6.4 },
  ];

  const costBreak = [
    { label: "Material", value: 64.10, pct: 38, color: "var(--accent)" },
    { label: "Machine time", value: 41.20, pct: 24, color: "var(--info)" },
    { label: "Electricity", value: 8.40, pct: 5, color: "var(--warn)" },
    { label: "Labour", value: 32.00, pct: 19, color: "var(--violet)" },
    { label: "Overhead", value: 14.50, pct: 8, color: "var(--text-muted)" },
    { label: "Failure buffer", value: 9.80, pct: 6, color: "var(--danger)" },
  ];

  return { clients, printers, orders, stages, stageMeta, filaments, kpis, cart, costBreak };
})();
