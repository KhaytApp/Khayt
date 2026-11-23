import SwiftUI
import KhaytCore

/// A printer's state, in one capsule (C2; Figma Qqxg4imtKVgC3TfNGcRGOk, page
/// 23, frame 3): Printing, Paused, Idle, Reconnecting…, Not known yet, Error,
/// Offline. The state is the shared rule's (`KhaytEngine.machineChips`), read
/// after every sweep; this only draws it.
///
/// Never colour alone: each chip says its state in words, and the dot repeats
/// it for a glance. Paused is amber and counts as busy. Reconnecting is grey:
/// one missed poll is not a fault.
struct MachineStateChip: View {
    let chip: KhaytEngine.MachineChip
    let words: Words

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(Self.word(chip, words))
                .font(.caption.weight(.medium))
                .foregroundStyle(text)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(wash, in: Capsule())
        .overlay(Capsule().strokeBorder(outlined ? Color(nsColor: .separatorColor) : .clear))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    static func key(_ chip: KhaytEngine.MachineChip) -> String { "mac.chip_" + chip.rawValue }
    static func word(_ chip: KhaytEngine.MachineChip, _ words: Words) -> String { words.callIt(key(chip)) }

    private var dot: Color {
        switch chip {
        case .printing: Khayt.brand
        case .paused: Khayt.attention
        case .idle, .reconnecting: Color.secondary
        case .unknown: Color.secondary.opacity(0.4)
        case .error, .offline: Khayt.late
        }
    }

    private var text: Color {
        switch chip {
        case .printing, .idle, .reconnecting: .primary
        case .paused: Khayt.attention
        case .unknown: .secondary
        case .error, .offline: Khayt.late
        }
    }

    /// Tinted for the three that ask to be looked at; outlined for the rest.
    private var wash: Color {
        switch chip {
        case .paused: Khayt.attention.opacity(0.13)
        case .error, .offline: Khayt.late.opacity(0.13)
        default: Color(nsColor: .controlBackgroundColor)
        }
    }

    private var outlined: Bool {
        switch chip {
        case .paused, .error, .offline: false
        default: true
        }
    }
}
