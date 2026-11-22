import SwiftUI
import WidgetKit

/**
 * The Money widget's face: today's takings, what customers owe, and how many
 * spools are low.
 *
 * Compiled into the widget AND the app, like `PrintActivityViews.swift`, so
 * `MoneyWidgetTests` can render it to a picture (`bundle` is the widget's
 * table there; `.main` in the widget).
 *
 * ── IT DRAWS, IT DOES NOT COUNT ──────────────────────────────────────────
 *
 * Every figure and its text arrive worked out in `WidgetMoney` (the app's
 * `WidgetFigures`, from the same code Home and End of Day use). Nothing here
 * adds, converts or formats money.
 *
 * ── PRIVACY ──────────────────────────────────────────────────────────────
 *
 * The amounts are `.privacySensitive()`, so a locked phone (Lock Screen,
 * StandBy, a redacted preview) shows placeholders, not a shop's money. The
 * view also reads `redactionReasons` itself and writes no figure at all when
 * asked to hide, and treats the dimmed always-on display (`isLuminanceReduced`,
 * which only happens on a locked phone) the same way. The low-stock count is
 * not money and stays.
 */
struct KhaytMoneyView: View {
    enum Size { case small, medium }

    let snapshot: WidgetSnapshot?
    let now: Date
    let size: Size
    var bundle: Bundle = .main

    @Environment(\.redactionReasons) private var redaction
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    private typealias Look = PrintActivityLook

    /// Hide the amounts: a redacted context (locked, placeholder) or the
    /// always-on display.
    private var hidesMoney: Bool {
        redaction.contains(.privacy) || redaction.contains(.placeholder) || luminanceReduced
    }

    /// Full colour on the Home Screen; the system's tint (accented, vibrant)
    /// takes primary and secondary only.
    private var fullColor: Bool { renderingMode == .fullColor && !luminanceReduced }
    private var ink: Color { fullColor ? Look.ink : .primary }
    private var note: Color { fullColor ? Look.note : .secondary }
    private var lowTone: Color { fullColor ? Look.attention : .primary }

    var body: some View {
        Group {
            if let snapshot, let money = snapshot.money {
                switch size {
                case .small: small(snapshot, money)
                case .medium: medium(snapshot, money)
                }
            } else {
                placeholder
            }
        }
        .modifier(WidgetLatinDigits())
    }

    // MARK: small

    private func small(_ s: WidgetSnapshot, _ m: WidgetMoney) -> some View {
        let stale = WidgetFreshness.isStale(m.asOf, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            header(s, compact: true)
            Spacer(minLength: 4)
            VStack(alignment: .leading, spacing: 5) {
                label("Earned today")
                amount(m.takingsText, m.mark, size: 26)
                    .padding(.bottom, 2)
                HStack(alignment: .firstTextBaseline) {
                    label("Owed")
                    Spacer(minLength: 4)
                    amount(m.owedText, m.mark, size: 14)
                }
                HStack(alignment: .firstTextBaseline) {
                    label("Low stock")
                    Spacer(minLength: 4)
                    lowCount(m.lowStock, size: 14)
                }
            }
            .opacity(WidgetFreshness.opacity(stale: stale))
            Spacer(minLength: 4)
            WidgetAgeLabel(asOf: m.asOf, now: now)
        }
    }

    // MARK: medium

    private func medium(_ s: WidgetSnapshot, _ m: WidgetMoney) -> some View {
        let stale = WidgetFreshness.isStale(m.asOf, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                header(s, compact: false)
                Spacer(minLength: 8)
                WidgetAgeLabel(asOf: m.asOf, now: now, size: 11)
            }
            Spacer(minLength: 6)
            HStack(alignment: .top, spacing: 12) {
                column("Earned today") {
                    amount(m.takingsText, m.mark, size: 26)
                }
                rule
                column("Owed") {
                    amount(m.owedText, m.mark, size: 26)
                    if m.unpaid > 0 {
                        Text("\(m.unpaid) unpaid", bundle: bundle)
                            .font(Look.text(11))
                            .foregroundStyle(note)
                            .lineLimit(1)
                    }
                }
                rule
                column("Low stock") {
                    lowCount(m.lowStock, size: 26)
                    Text("to reorder", bundle: bundle)
                        .font(Look.text(11))
                        .foregroundStyle(note)
                        .lineLimit(1)
                }
            }
            .opacity(WidgetFreshness.opacity(stale: stale))
            Spacer(minLength: 0)
        }
    }

    // MARK: pieces

    private func header(_ s: WidgetSnapshot, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "banknote")
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(fullColor ? Look.brand : .primary)
                .widgetAccentable()
            Text(verbatim: s.shopName.isEmpty ? "Khayt" : s.shopName)
                .font(Look.text(compact ? 11 : 12, .semibold))
                .foregroundStyle(ink)
                .lineLimit(1)
        }
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: bundle)
            .font(Look.text(10, .semibold))
            .foregroundStyle(note)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func column<Content: View>(_ key: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            label(key)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rule: some View {
        Rectangle().fill(fullColor ? Look.track : Color.secondary.opacity(0.4)).frame(width: 1, height: 44)
    }

    /// The figure and the currency's mark, left to right in every language
    /// (as Home's hero), aligned to the reading side by the stack around it.
    /// The figure is the private part.
    private func amount(_ figure: String, _ mark: String, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: hidesMoney ? "••••" : figure)
                .font(Look.display(size).monospacedDigit())
                .foregroundStyle(ink)
                .privacySensitive()
                .widgetAccentable()
            if !mark.isEmpty {
                // The system face: the riyal sign (U+20C1) is not in Archivo.
                Text(verbatim: mark)
                    .font(.system(size: max(10, size * 0.5), weight: .semibold))
                    .foregroundStyle(note)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func lowCount(_ n: Int, size: CGFloat) -> some View {
        Text(verbatim: "\(n)")
            .font(Look.display(size).monospacedDigit())
            .foregroundStyle(n > 0 ? lowTone : ink)
            .widgetAccentable()
    }

    /// No shop, the sample shop or no book: no figures at all, invented or zero.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "banknote")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(fullColor ? Look.brand : .primary)
                    .widgetAccentable()
                Text(verbatim: "Khayt").font(Look.display(15)).foregroundStyle(ink)
            }
            Spacer(minLength: 0)
            Text("Pair Khayt with your shop to see its money here.", bundle: bundle)
                .font(Look.text(12))
                .foregroundStyle(note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
