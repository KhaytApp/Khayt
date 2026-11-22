import Foundation

/// The currencies a shop can price in — ported to Swift.
///
/// Shared in the first place because the invoice formats money against this
/// table and this app prints the invoice: with the table only in the renderer,
/// the Mac had a one-row stand-in that knew SAR and nothing else, so a shop
/// pricing in euros printed "EUR" where the document prints "€".
///
/// That is the whole reason a data table is worth a parity test. The symbols
/// are not decoration — `€`, `₺`, `₹`, `R$`, `CA$` — and a table transcribed by
/// hand is a table with one wrong symbol in it. `CurrenciesParityTests` compares
/// every code, symbol, label and position against the JavaScript rather than
/// spot-checking a few.
public enum Currencies {

    public struct Currency: Sendable, Equatable {
        public let symbol: String
        public let label: String
        /// `before` or `after` the amount.
        public let pos: String
    }

    public static let all: [String: Currency] = [
        "SAR": .init(symbol: "SAR", label: "Saudi Riyal (SAR)", pos: "after"),
        "AED": .init(symbol: "AED", label: "UAE Dirham (AED)", pos: "after"),
        "KWD": .init(symbol: "KWD", label: "Kuwaiti Dinar (KWD)", pos: "after"),
        "BHD": .init(symbol: "BHD", label: "Bahraini Dinar (BHD)", pos: "after"),
        "QAR": .init(symbol: "QAR", label: "Qatari Riyal (QAR)", pos: "after"),
        "OMR": .init(symbol: "OMR", label: "Omani Rial (OMR)", pos: "after"),
        "EGP": .init(symbol: "EGP", label: "Egyptian Pound (EGP)", pos: "after"),
        "MAD": .init(symbol: "MAD", label: "Moroccan Dirham (MAD)", pos: "after"),
        "TND": .init(symbol: "TND", label: "Tunisian Dinar (TND)", pos: "after"),
        "DZD": .init(symbol: "DZD", label: "Algerian Dinar (DZD)", pos: "after"),
        "IQD": .init(symbol: "IQD", label: "Iraqi Dinar (IQD)", pos: "after"),
        "JOD": .init(symbol: "JOD", label: "Jordanian Dinar (JOD)", pos: "after"),
        "USD": .init(symbol: "$", label: "US Dollar (USD)", pos: "before"),
        "EUR": .init(symbol: "€", label: "Euro (EUR)", pos: "before"),
        "GBP": .init(symbol: "£", label: "British Pound (GBP)", pos: "before"),
        "CAD": .init(symbol: "CA$", label: "Canadian Dollar (CAD)", pos: "before"),
        "AUD": .init(symbol: "A$", label: "Australian Dollar (AUD)", pos: "before"),
        "CHF": .init(symbol: "CHF", label: "Swiss Franc (CHF)", pos: "before"),
        "TRY": .init(symbol: "₺", label: "Turkish Lira (TRY)", pos: "before"),
        "INR": .init(symbol: "₹", label: "Indian Rupee (INR)", pos: "before"),
        "JPY": .init(symbol: "¥", label: "Japanese Yen (JPY)", pos: "before"),
        "CNY": .init(symbol: "¥", label: "Chinese Yuan (CNY)", pos: "before"),
        "KRW": .init(symbol: "₩", label: "South Korean Won (KRW)", pos: "before"),
        "BRL": .init(symbol: "R$", label: "Brazilian Real (BRL)", pos: "before"),
        "MXN": .init(symbol: "$", label: "Mexican Peso (MXN)", pos: "before"),
        "ZAR": .init(symbol: "R", label: "South African Rand (ZAR)", pos: "before"),
        "NGN": .init(symbol: "₦", label: "Nigerian Naira (NGN)", pos: "before"),
    ]
}
