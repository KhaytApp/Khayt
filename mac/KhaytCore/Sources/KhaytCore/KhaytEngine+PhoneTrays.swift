import Foundation

/// The spool tags a printer's heads read, as a paired phone is told them
/// (`GET /api/printer/{machineId}/trays`; iPhone frame 7a, "A spool tag on a
/// head").
///
/// The tag and which of the shop's spools it is are `lib/rfid-tray.js`
/// (`trays`, `spoolMatch`), the rule the Windows/Linux app's own "Which spool
/// is in head N" uses: there is no second matcher in Swift. In KhaytCore so
/// the answer's shape is the phone's to decode from the same types.
extension KhaytEngine {

    /// One row per head, in the printer's order:
    ///
    ///     { head: 1,                    // as people count them
    ///       tag: { vendor, manufacturer, material, sub, colours, weightG,
    ///              diameterMm, official } | null,
    ///       key: "…",                   // what this tag is; "" with no tag
    ///       match: { kind: "link", spoolId, candidates: [spoolId…] }   // the one strong match, then the near ones
    ///            | { kind: "ask", candidates: [spoolId…] }   // best first
    ///            | { kind: "new" } | { kind: "none" },
    ///       prefill: { material, color, brand, weight } | null,   // what "Add spool from the tag" would add
    ///       linked: spoolId | null }    // the spool already recorded in this head
    ///
    /// - `filamentDetect`: the printer's `filament_detect` object.
    /// - `spools`: the shop's `inventory` records, raw.
    /// - `linked`: the machine's `headSpools` (`{ "0": spoolId, … }`, keyed
    ///   from zero as the Windows/Linux app writes it), or `.null`. A link to
    ///   a spool that is no longer on the shelf is not reported.
    ///
    /// `key` is everything the tag says, so a phone can send back what it was
    /// showing and a head whose spool was swapped meanwhile is noticed. Two
    /// identical spools have the same key: a tag has no number of its own in
    /// what the printer reports.
    public func phoneTrays(filamentDetect: JSONValue, spools: [JSONValue], linked: JSONValue = .null) throws -> [JSONValue] {
        try runtime.call2("""
            (function (detect, spools, linked) {
              var RT = globalThis.KhaytRfidTray;
              var shelf = Array.isArray(spools) ? spools : [];
              var known = Object.create(null);
              shelf.forEach(function (s) { if (s && s.id != null && !s.deleted) known[String(s.id)] = true; });
              var held = linked && typeof linked === 'object' && !Array.isArray(linked) ? linked : {};
              var live = shelf.filter(function (s) { return s && !s.deleted; });
              return RT.trays(detect).map(function (tag, i) {
                var m = RT.spoolMatch(tag, live);
                var match = { kind: m.action };
                if (m.action === 'link') {
                  match.spoolId = m.spoolId;
                  // "Choose another" needs something to list. The rule names
                  // only its one strong match, so it is asked again WITHOUT
                  // that spool: what it then offers are the near ones, by the
                  // same rule and the same exclusions (deleted, used up, resin).
                  var rest = RT.spoolMatch(tag, live.filter(function (s) { return String(s.id) !== String(m.spoolId); }));
                  var near = rest.action === 'link' ? [rest.spoolId] : (rest.action === 'ask' ? rest.candidates.map(function (c) { return c.spoolId; }) : []);
                  match.candidates = [m.spoolId].concat(near);
                }
                if (m.action === 'ask') match.candidates = m.candidates.map(function (c) { return c.spoolId; });
                var p = tag ? (RT.spoolMatch(tag, []).prefill || null) : null;
                var l = Object.prototype.hasOwnProperty.call(held, String(i)) ? held[String(i)] : null;
                return {
                  head: i + 1,
                  tag: tag ? { vendor: tag.vendor, manufacturer: tag.manufacturer, material: tag.material, sub: tag.sub,
                               colours: tag.colours, weightG: tag.weightG, diameterMm: tag.diameterMm, official: tag.official } : null,
                  key: tag ? JSON.stringify([tag.vendor, tag.manufacturer, tag.material, tag.sub, tag.colours, tag.weightG,
                                             tag.diameterMm, tag.lengthM, tag.sku, tag.official]) : '',
                  match: match,
                  prefill: p ? { material: p.material, color: p.color, brand: p.brand, weight: p.weight } : null,
                  linked: (typeof l === 'string' && known[l]) ? l : null
                };
              });
            })(ARG0, ARG1, ARG2)
            """, [filamentDetect, .array(spools), linked], as: [JSONValue].self)
    }
}
