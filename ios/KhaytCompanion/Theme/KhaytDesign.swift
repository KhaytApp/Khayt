import SwiftUI

/// Design tokens — the 2026 redesign (Figma R9W19Jakt19nKs1yM5GEde), on the
/// website's published library and the same numbers the Mac's `Palette.swift`
/// and `Surface.swift` use since #2183: cool paper in light, the website's
/// navy in dark, the brand blue #216DCA / #4C97F0.
///
/// The names this app already used are kept and mapped onto these, so every
/// screen moves to the new palette at once.
///
/// Stages follow the Mac's Today: printing is `live` green, QC and on hold are
/// `hold` violet, done is `done`, pending and post are quiet `note`. The amber
/// `thread` is for progress and "today" only — a graphic colour, never text
/// (#F2A541 on white is about 2:1).
enum KhaytDesign {
    // ── The palette ─────────────────────────────────────────────────────
    static let ground = Color(light: 0xF6F8F8, dark: 0x06182F)
    static let surfaceV2 = Color(light: 0xFFFFFF, dark: 0x0D2444)
    static let sunk = Color(light: 0xEEF1F1, dark: 0x0A2140)
    static let hairlineV2 = Color(light: 0xE3E6E8, dark: 0x1F3A5E)
    static let brandV2 = Color(light: 0x216DCA, dark: 0x4C97F0)
    static let onBrand = Color(light: 0xFFFFFF, dark: 0x0B1622)
    static let hot = Color(light: 0xAF3E18, dark: 0xF0763D)
    static let done = Color(light: 0x1B5E4F, dark: 0x4FBFA0)
    static let attention = Color(light: 0x8A5A0B, dark: 0xE0A73C)
    static let late = Color(light: 0xBB2D44, dark: 0xF2564A)
    static let note = Color(light: 0x5A636D, dark: 0x8AA4C2)
    static let ink = Color(light: 0x101417, dark: 0xEAF2FB)

    // ── New in the redesign (the Mac's names and values) ───────────────
    /// Progress bars, the "today" chip, the week line. Graphic only.
    static let thread = Color(light: 0xF2A541, dark: 0xF2A541)
    static let threadWash = Color(light: 0xFDF1DE, dark: 0x3A2C14)
    /// A machine printing right now.
    static let live = Color(light: 0x13803F, dark: 0x34D27A)
    /// Ready to collect.
    static let collect = Color(light: 0x0E7A70, dark: 0x3FD0C0)
    /// On hold and quality check.
    static let hold = Color(light: 0x6B52B5, dark: 0xB49CFF)
    /// Waiting on someone else — a request not taken yet, a quote out.
    /// Steel: quieter than amber progress, never read as trouble.
    static let pending = Color(light: 0x5E6C84, dark: 0xA9B8CF)
    static let pendingWash = Color(light: 0xEDF0F4, dark: 0x3A4658)
    /// The ring round a colour swatch, so a black spool shows on navy and a
    /// white one on paper (ink/tertiary in the Figma file).
    static let swatchRing = note.opacity(0.55)
    /// The well a thumbnail sits in: lighter than the card in dark.
    static let well = Color(light: 0xEEF1F3, dark: 0x2A4670)
    /// The icon's navy, for the mark's tile and nothing that is read.
    static let navy = Color(light: 0x0A2A50, dark: 0x0A2A50)

    // ── The names the app uses, on the design's palette ────────────────
    static let bg = ground
    static let bg2 = ground
    static let surface = surfaceV2
    static let surface2 = sunk
    static let surface3 = sunk

    static let text = ink
    static let textDim = note
    static let textMuted = note.opacity(0.75)
    static let textFaint = hairlineV2

    static let brand = brandV2
    static let accent = brand
    static let accentSoft = brand.opacity(0.14)
    static let brandDim = accentSoft
    static let accentText = brand
    static let accentLine = brand.opacity(0.40)

    static let ok = done
    static let okSoft = done.opacity(0.16)
    static let warn = attention
    static let warnSoft = attention.opacity(0.16)
    static let danger = late
    static let dangerSoft = late.opacity(0.16)
    static let orange = hot
    static let orangeSoft = hot.opacity(0.16)
    static let info = note
    static let infoSoft = note.opacity(0.16)
    static let violet = note
    static let violetSoft = note.opacity(0.16)

    static let border = hairlineV2
    static let hairline = hairlineV2
    static let sep = hairlineV2

    static let tabBg = ground
    static let navBg = ground
    static let sheetBg = surfaceV2

    static let radiusSM: CGFloat = 10
    static let radiusMD: CGFloat = 12
    static let radiusLG: CGFloat = 16
    static let radiusXL: CGFloat = 22

    static let pad: CGFloat = 16

    /// One colour per stage, as on the Mac's Today.
    static func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "pending": return note
        case "printing": return live
        case "post": return note
        case "qc", "on_hold": return hold
        case "completed", "delivered", "shipped": return done
        case "idle", "ready": return ok
        case "busy": return live
        case "error": return danger
        default: return textDim
        }
    }

    /// Whether a stage earns a coloured rail on its row: printing and QC, and
    /// nothing else ("rails stay rare").
    static func isRailed(_ status: String) -> Bool {
        ["printing", "qc"].contains(status.lowercased())
    }

    static func statusSoft(for status: String) -> Color {
        statusColor(for: status).opacity(0.16)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Dynamic color that resolves differently in light vs dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Full-screen background (flat; mockup has no accent glow).
struct KhaytScreenBackground: View {
    var body: some View {
        KhaytDesign.bg.ignoresSafeArea()
    }
}

struct KhaytEyebrow: View {
    let text: String
    var body: some View {
        Text(L10n.usesArabicLayout ? text : text.uppercased())
            .font(L10n.usesArabicLayout ? .khayt(10.5, .bold, relativeTo: .caption2) : .khaytMono(10.5, .medium, relativeTo: .caption2))
            .khaytTracking(1.0)
            .foregroundStyle(KhaytDesign.textMuted)
    }
}

struct KhaytSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.khayt(15, .semibold, relativeTo: .headline))
            .foregroundStyle(KhaytDesign.text)
    }
}

struct KhaytThreadDivider: View {
    var body: some View {
        Rectangle()
            .fill(KhaytDesign.sep)
            .frame(height: 0.5)
    }
}

