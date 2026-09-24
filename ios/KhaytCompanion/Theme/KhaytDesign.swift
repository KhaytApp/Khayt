import SwiftUI

/// Design tokens — `design/ios-v2/` (Claude Design, v2): the prototype's own
/// `DARK` and `LIGHT` palettes, warm neutrals with a blue brand.
///
/// The names this app already used are kept and mapped onto the design's, so
/// every screen moves to the new palette at once; the design's own names
/// (`ground`, `sunk`, `hot`, `attention`, `note`, `late`) are here too, for
/// the screens rebuilt against it.
///
/// The stage colours are the prototype's `TONE`: printing is `hot`, QC is
/// `attention`, done is `done`, and pending and post are quiet `note` — only
/// printing and QC earn a rail ("rails stay rare").
enum KhaytDesign {
    // ── The design's palette ────────────────────────────────────────────
    static let ground = Color(light: 0xEFEBE3, dark: 0x16130F)
    static let surfaceV2 = Color(light: 0xFBF9F5, dark: 0x201C17)
    static let sunk = Color(light: 0xE3DED3, dark: 0x2A251E)
    static let hairlineV2 = Color(light: 0xDCD5C8, dark: 0x3A342C)
    static let brandV2 = Color(light: 0x0B54AD, dark: 0x4591ED)
    static let onBrand = Color(light: 0xFFFFFF, dark: 0x0B1622)
    static let hot = Color(light: 0xAF3E18, dark: 0xF0763D)
    static let done = Color(light: 0x1B5E4F, dark: 0x4FBFA0)
    static let attention = Color(light: 0x8A5A0B, dark: 0xE0A73C)
    static let late = Color(light: 0xBB2D44, dark: 0xF2564A)
    static let note = Color(light: 0x4F5B69, dark: 0x9EA7B3)
    static let ink = Color(light: 0x1E1A15, dark: 0xF2EDE4)

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

    /// The prototype's `TONE`.
    static func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "pending": return note
        case "printing": return hot
        case "post": return note
        case "qc": return attention
        case "completed", "delivered", "shipped": return done
        case "on_hold": return textMuted
        case "idle", "ready": return ok
        case "busy": return hot
        case "error": return danger
        default: return textDim
        }
    }

    /// Whether a stage earns a coloured rail on its row — the prototype's
    /// `RAILED`: printing and QC, and nothing else.
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

/// Card surface — `khayt-design.jsx` Card (radius 16, no border).
struct KhaytCard<Content: View>: View {
    var padding: CGFloat = KhaytDesign.pad
    var bordered: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: KhaytDesign.radiusLG)
                        .stroke(KhaytDesign.border, lineWidth: 1)
                }
            }
    }
}

/// Home stat tile — `khayt-home.jsx` StatBlock.
struct KhaytStatBlock: View {
    let value: String
    let label: String
    let color: Color
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(KhaytDesign.textDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(KhaytDesign.textMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusLG))
        .overlay(
            RoundedRectangle(cornerRadius: KhaytDesign.radiusLG)
                .stroke(KhaytDesign.border, lineWidth: 0.5)
        )
    }
}

/// Section header — `SectionLabel` in mockup.
struct KhaytSectionHeader: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(L10n.usesArabicLayout ? text : text.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(KhaytDesign.textDim)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KhaytDesign.brand)
            }
        }
        .padding(.horizontal, KhaytDesign.pad)
    }
}

struct KhaytEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(KhaytDesign.textMuted)
    }
}

struct KhaytSectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(KhaytDesign.text)
    }
}

struct KhaytMetric: View {
    let value: String
    let unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(KhaytDesign.text)
            if let unit {
                Text(unit)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(KhaytDesign.textMuted)
            }
        }
    }
}

struct KhaytPill: View {
    let text: String
    var color: Color = KhaytDesign.brand
    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: Capsule())
    }
}

struct KhaytPrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusMD))
        }
    }
}

struct KhaytGhostButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KhaytDesign.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(KhaytDesign.surface2, in: RoundedRectangle(cornerRadius: KhaytDesign.radiusSM))
        }
    }
}

struct KhaytThreadDivider: View {
    var body: some View {
        Rectangle()
            .fill(KhaytDesign.sep)
            .frame(height: 0.5)
    }
}

struct KhaytLogoMark: View {
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(KhaytDesign.brandDim)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28)
                        .stroke(KhaytDesign.brand.opacity(0.35), lineWidth: 1)
                )
            Text("خ")
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(KhaytDesign.brand)
        }
        .frame(width: size, height: size)
    }
}
