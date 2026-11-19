import Foundation

/// A product's labour and packaging, charged once at the job level
/// (`lib/product-pricing.js productJobParts`, #2581). Shop currency.
struct ProductOnceCosts: Equatable, Sendable {
    var labour: Double
    var packaging: Double
    static let none = ProductOnceCosts(labour: 0, packaging: 0)

    /// `count` of the product: the parts are scaled per piece today, so these
    /// are too, until Turki decides how a quantity above 1 is costed.
    func times(_ count: Int) -> ProductOnceCosts {
        let n = Double(max(1, count))
        return ProductOnceCosts(labour: labour * n, packaging: packaging * n)
    }

    static func + (a: ProductOnceCosts, b: ProductOnceCosts) -> ProductOnceCosts {
        ProductOnceCosts(labour: a.labour + b.labour, packaging: a.packaging + b.packaging)
    }
}
