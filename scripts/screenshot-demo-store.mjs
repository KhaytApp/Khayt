/** Demo store for README screenshots — rich but self-contained. */
import zlib from 'node:zlib';

function isoDate(d) {
  return d.toISOString().slice(0, 10);
}

function daysAgo(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return isoDate(d);
}

// Minimal RGB PNG encoder — the app's safeImageSrc only accepts base64 PNG/JPEG
// data URIs (not SVG), so demo thumbnails are generated as real PNGs. Renders a
// diagonal gradient with a lighter centred "part" block, tinted per call.
function pngChunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(body) >>> 0, 0);
  return Buffer.concat([len, body, crc]);
}
function makeThumbPng(a, b, accent) {
  const w = 320, h = 240;
  const raw = Buffer.alloc((w * 3 + 1) * h);
  let o = 0;
  const inBlock = (x, y) => x >= 92 && x < 228 && y >= 60 && y < 180;
  for (let y = 0; y < h; y++) {
    raw[o++] = 0; // filter byte
    for (let x = 0; x < w; x++) {
      const t = (x / w + y / h) / 2;
      let r = Math.round(a[0] + (b[0] - a[0]) * t);
      let g = Math.round(a[1] + (b[1] - a[1]) * t);
      let bl = Math.round(a[2] + (b[2] - a[2]) * t);
      if (inBlock(x, y)) { r = accent[0]; g = accent[1]; bl = accent[2]; }
      raw[o++] = r; raw[o++] = g; raw[o++] = bl;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlib.deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
  return 'data:image/png;base64,' + png.toString('base64');
}

const DEMO_THUMB = makeThumbPng([15, 23, 42], [30, 41, 59], [56, 189, 248]);
const THUMB_GOLD = makeThumbPng([32, 26, 12], [60, 48, 20], [201, 162, 39]);
const THUMB_GREEN = makeThumbPng([12, 30, 24], [22, 52, 40], [52, 211, 153]);
const THUMB_ROSE = makeThumbPng([34, 14, 24], [58, 24, 40], [244, 114, 182]);

export function buildScreenshotDemoStore() {
  const today = isoDate(new Date());
  const clients = [
    { id: 'C1', nameEn: 'Najd Robotics', nameAr: 'نجد للروبوتات', phone: '+966 50 111 2233', email: 'ops@najd.example', tier: 'Gold', creditLimit: 5000 },
    { id: 'C2', nameEn: 'Tuwaiq Models', nameAr: 'نماذج طويق', phone: '+966 55 444 5566', email: 'print@tuwaiq.example', tier: 'Gold', creditLimit: 8000 },
    { id: 'C3', nameEn: 'Atelier Hessa', nameAr: 'أتيليه حصة', phone: '+966 54 777 8899', tier: 'Silver' },
    { id: 'C4', nameEn: 'Coastal Drones', nameAr: 'درونز الساحل', phone: '+966 56 222 3344', tier: 'Silver' },
    { id: 'C5', nameEn: 'Khalid M.', phone: '+966 53 999 0011', tier: 'Bronze' },
  ];

  const machines = [
    { id: 'M1', name: 'Bambu Lab X1C', tech: 'FDM', hourlyRate: 12, serviceInterval: 500, lastServiceHours: 120 },
    { id: 'M2', name: 'Prusa MK4S', tech: 'FDM', hourlyRate: 10, serviceInterval: 400, lastServiceHours: 80 },
    { id: 'M3', name: 'Creality K1 Max', tech: 'FDM', hourlyRate: 8, serviceInterval: 350, lastServiceHours: 200 },
    { id: 'M4', name: 'Saturn 4 Ultra', tech: 'Resin', hourlyRate: 9, serviceInterval: 300, lastServiceHours: 40 },
  ];

  const inventory = [
    { id: 'S1', material: 'PLA+ Black', brand: 'Polymaker', weight: 2840, cost: 75, reorderPoint: 500, color: '#1a1a1a' },
    { id: 'S2', material: 'PETG White', brand: 'eSUN', weight: 640, cost: 82, reorderPoint: 400, color: '#f0f0f0' },
    { id: 'S3', material: 'PLA Silk Gold', brand: 'SUNLU', weight: 210, cost: 95, reorderPoint: 300, color: '#c9a227' },
    { id: 'S4', material: 'ASA Black', brand: 'Prusament', weight: 1450, cost: 110, reorderPoint: 400, color: '#222222' },
    { id: 'S5', material: 'TPU 95A', brand: 'Polymaker', weight: 380, cost: 130, reorderPoint: 250, color: '#2a2a2a' },
    { id: 'S6', material: 'Resin Grey 8K', brand: 'Siraya Tech', weight: 1100, cost: 145, reorderPoint: 500, color: '#8a8f99' },
  ];

  const mkOrder = (id, project, clientId, status, daysBack, extra = {}) => ({
    id,
    project,
    clientId,
    client: clients.find(c => c.id === clientId)?.nameEn || '',
    date: daysAgo(daysBack),
    dueDate: status === 'completed' ? daysAgo(daysBack - 1) : daysAgo(-2),
    status,
    machineId: extra.machineId || 'M1',
    machine: machines.find(m => m.id === (extra.machineId || 'M1'))?.name || 'Bambu Lab X1C',
    price: extra.price ?? 480,
    paidAmount: extra.paidAmount ?? (status === 'completed' ? 0 : 0),
    printTime: extra.printTime ?? 6,
    material: extra.material ?? 'PLA+ Black',
    parts: [{ name: project, printWeight: 120, printTime: 4, filamentId: 'S1' }],
    ...extra,
  });

  const printLog = [
    mkOrder('O-1042', 'Gearbox housing batch', 'C1', 'printing', 1, { machineId: 'M1', price: 480, printTime: 6.1 }),
    mkOrder('O-1041', 'Figurine batch ×12', 'C2', 'printing', 2, { machineId: 'M1', price: 1240, material: 'PETG White' }),
    mkOrder('O-1040', 'Ring masters (resin)', 'C3', 'printing', 1, { machineId: 'M4', price: 720, material: 'Resin Grey 8K', printTime: 5.2 }),
    mkOrder('O-1039', 'Drone arm prototype', 'C4', 'pending', 3, { machineId: 'M3', price: 360 }),
    mkOrder('O-1038', 'Cable clip set', 'C5', 'pending', 4, { machineId: 'M2', price: 95, printTime: 1.6 }),
    mkOrder('O-1037', 'Bracket redesign', 'C2', 'pending', 4, { machineId: 'M2', price: 210 }),
    mkOrder('O-1036', 'Enclosure panels', 'C2', 'post', 5, { machineId: 'M1', price: 640, printTime: 9 }),
    mkOrder('O-1035', 'TPU gaskets', 'C1', 'post', 5, { machineId: 'M2', price: 180, material: 'TPU 95A' }),
    mkOrder('O-1034', 'Display stand', 'C3', 'qc', 6, { machineId: 'M4', price: 540 }),
    mkOrder('O-1033', 'ASA propeller', 'C4', 'qc', 6, { machineId: 'M3', price: 420, material: 'ASA Black' }),
    mkOrder('O-1032', 'White PLA trophies', 'C2', 'completed', 8, {
      price: 980, paidAmount: 980, printTime: 11, productId: 'P2',
      printPhotos: [{ thumb: DEMO_THUMB, filename: 'trophies.jpg' }],
    }),
    mkOrder('O-1031', 'Phone stand', 'C5', 'completed', 9, {
      price: 110, paidAmount: 110, productId: 'P1',
      printPhotos: [{ thumb: DEMO_THUMB, filename: 'phone-stand.jpg' }],
    }),
    mkOrder('O-1030', 'Sensor mount', 'C1', 'completed', 12, {
      price: 320, paidAmount: 200, productId: 'P3',
      printPhotos: [{ thumb: DEMO_THUMB, filename: 'sensor-mount.jpg' }],
    }),
    mkOrder('O-1029', 'Lens cap', 'C3', 'completed', 15, { price: 85, paidAmount: 85 }),
    mkOrder('O-1028', 'Batch hooks', 'C4', 'completed', 18, { price: 240, paidAmount: 0 }),
    ...Array.from({ length: 8 }, (_, i) =>
      mkOrder(`O-10${10 - i}`, `Production job ${10 - i}`, 'C1', 'completed', 20 + i, {
        price: 400 + i * 50,
        paidAmount: i % 2 === 0 ? 400 + i * 50 : 0,
        date: daysAgo(22 + i),
      })
    ),
  ];

  // Revenue in current month for dashboard goal bar
  for (let i = 0; i < 20; i++) {
    printLog.push(mkOrder(`O-R${i}`, `May order ${i + 1}`, 'C2', 'completed', i % 28, {
      price: 280 + (i * 37) % 420,
      paidAmount: 280 + (i * 37) % 420,
      date: daysAgo(i % 28),
    }));
  }

  return {
    version: 5,
    settings: {
      lang: 'en',
      theme: 'dark',
      mode: 'professional',
      firstRun: false,
      firstRunDone: true,
      businessName: 'Khayt Studio Demo',
      bizEn: 'Al-Athar 3D Print Studio',
      bizAr: 'استوديو الأثر للطباعة ثلاثية الأبعاد',
      taglineEn: 'Production · Invoicing · Analytics',
      currency: 'SAR',
      monthlyGoal: 8000,
      lowStockThreshold: 400,
      loyaltyEnabled: true,
      loyaltyTiers: [
        { name: 'Bronze', minOrders: 1, minSpend: 0 },
        { name: 'Silver', minOrders: 10, minSpend: 3000 },
        { name: 'Gold', minOrders: 25, minSpend: 10000 },
      ],
      dismissedNotifs: {},
      staleHours: { pending: 72, printing: 48 },
      zatcaPhase2: {
        enabled: true,
        environment: 'sandbox',
        city: 'Riyadh',
        orgName: 'Al-Athar 3D Print Studio',
        industry: '3D Printing',
      },
      emailConfig: {
        provider: 'custom',
        smtpHost: 'smtp.al-athar.example',
        smtpPort: 587,
        fromEmail: 'invoices@al-athar.example',
        fromName: 'Al-Athar 3D',
      },
    },
    printLog,
    clients,
    machines,
    inventory,
    templates: [],
    products: [
      { id: 'P1', nameEn: 'Cable clip set (×10)', nameAr: 'مجموعة مشابك', price: 95, parts: [{ name: 'Clip' }] },
      { id: 'P2', nameEn: 'Phone stand', nameAr: 'حامل هاتف', price: 110, parts: [{ name: 'Base' }, { name: 'Arm' }] },
      { id: 'P3', nameEn: 'Sensor mount', nameAr: 'حامل مستشعر', price: 160, parts: [{ name: 'Bracket' }] },
      { id: 'P4', nameEn: 'Gearbox housing', nameAr: 'غلاف علبة تروس', price: 240, parts: [{ name: 'Housing' }] },
      { id: 'P5', nameEn: 'Display stand', nameAr: 'حامل عرض', price: 180, parts: [{ name: 'Stand' }] },
      { id: 'P6', nameEn: 'Drone arm', nameAr: 'ذراع درون', price: 360, parts: [{ name: 'Arm' }] },
    ],
    printers: [],
    expenses: [
      { id: 'E1', date: daysAgo(5), category: 'Filament', amount: 450, note: 'Polymaker restock' },
      { id: 'E2', date: daysAgo(12), category: 'Maintenance', amount: 120, note: 'Nozzle kit' },
    ],
    waTemplates: [],
    wasteLog: [
      { id: 'W1', date: daysAgo(1), material: 'PLA+ Black', weight: 62, cost: 4.65, failureType: 'bed_adhesion', reason: 'Bed level drift' },
      { id: 'W2', date: daysAgo(3), material: 'PETG White', weight: 28, cost: 2.30, failureType: 'nozzle_jam', reason: 'Partial clog' },
      { id: 'W3', date: daysAgo(6), material: 'Resin Grey 8K', weight: 45, cost: 6.53, failureType: 'design_issue', reason: 'Heavy unsupported islands' },
      { id: 'W4', date: daysAgo(9), material: 'TPU 95A', weight: 18, cost: 2.34, failureType: 'stringing', reason: 'Dry box needed' },
      { id: 'W5', date: daysAgo(14), material: 'ASA Black', weight: 35, cost: 3.85, failureType: 'warping', reason: 'Chamber temp low' },
    ],
    machMaintLog: [],
    consumables: [],
    suppliers: [],
    purchaseOrders: [],
    testPrints: [],
    locations: [{ id: 'L1', name: 'Main workshop', isDefault: true }],
    operators: [],
    waitingList: [],
    waitingListHistory: [],
    timeEntries: [],
    shiftLogs: [],
    giftCards: [
      { code: 'GIFT500', balance: 350, initialBalance: 500, issuedTo: 'Khalid M.', expiresAt: daysAgo(-90), createdAt: daysAgo(14) },
      { code: 'NAJD250', balance: 250, initialBalance: 250, issuedTo: 'Najd Robotics', expiresAt: daysAgo(-180), createdAt: daysAgo(30) },
      { code: 'LOYAL100', balance: 0, initialBalance: 100, issuedTo: 'Atelier Hessa', expiresAt: daysAgo(-30), createdAt: daysAgo(60) },
    ],
    slicerProfiles: [],
    envLogs: [],
    printFiles: [
      {
        id: 'PF1', name: 'Gearbox housing v4', originalName: 'gearbox-housing-v4.3mf',
        createdAt: daysAgo(2) && Date.parse(daysAgo(2)), updatedAt: Date.parse(daysAgo(1)),
        sourceFile: { filename: 'gearbox.3mf', originalName: 'gearbox-housing-v4.3mf', size: 4_820_000, ext: '3mf', kind: 'model' },
        parsed: { layerHeight: 0.2, printTime: 6.1 }, material: 'PLA+ Black',
        colors: [{ hex: '#1a1a1a', grams: 96, label: 'Black' }, { hex: '#c9a227', grams: 24, label: 'Gold' }],
        swapCount: 3, thumb: THUMB_GOLD, tags: ['production', 'gearbox'], favorite: true,
        converted: [{ filename: 'converted-a1.3mf', ext: '3mf', size: 4_610_000, targetName: 'Bambu A1', createdAt: Date.parse(daysAgo(1)) }],
      },
      {
        id: 'PF2', name: 'Articulated dragon', originalName: 'dragon-print-in-place.3mf',
        createdAt: Date.parse(daysAgo(6)), updatedAt: Date.parse(daysAgo(6)),
        sourceFile: { filename: 'dragon.3mf', originalName: 'dragon-print-in-place.3mf', size: 12_400_000, ext: '3mf', kind: 'model' },
        parsed: { layerHeight: 0.16, printTime: 9.4 }, material: 'PLA Silk Gold',
        colors: [{ hex: '#c9a227', grams: 180, label: 'Silk Gold' }],
        swapCount: 0, thumb: THUMB_ROSE, tags: ['minis'], favorite: false,
      },
      {
        id: 'PF3', name: 'Enclosure front panel', originalName: 'enclosure-front.stl',
        createdAt: Date.parse(daysAgo(9)), updatedAt: Date.parse(daysAgo(8)),
        sourceFile: { filename: 'enclosure.stl', originalName: 'enclosure-front.stl', size: 2_100_000, ext: 'stl', kind: 'model' },
        parsed: {}, material: 'PETG White',
        colors: [], swapCount: 0, thumb: THUMB_GREEN, tags: ['enclosure', 'petg'], favorite: false,
      },
      {
        id: 'PF4', name: 'Cable clip (multicolour)', originalName: 'cable-clip-2c.3mf',
        createdAt: Date.parse(daysAgo(12)), updatedAt: Date.parse(daysAgo(12)),
        sourceFile: { filename: 'clip.3mf', originalName: 'cable-clip-2c.3mf', size: 640_000, ext: '3mf', kind: 'model' },
        parsed: { layerHeight: 0.2, printTime: 0.6 }, material: 'PLA+ Black',
        colors: [{ hex: '#1a1a1a', grams: 6, label: 'Black' }, { hex: '#f0f0f0', grams: 2, label: 'White' }],
        swapCount: 1, thumb: DEMO_THUMB, tags: ['functional'], favorite: false,
      },
    ],
  };
}
