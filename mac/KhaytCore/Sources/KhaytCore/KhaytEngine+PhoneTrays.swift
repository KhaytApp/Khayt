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

/// What each head of a printer holds, for the machine sheet's "Loaded on this
/// printer" (Mac file, page 25, frames 1 and 2; the Windows/Linux app's
/// `renderer/machines.js machineHeadsRows` and `openHeadLink`).
extension KhaytEngine {

    public struct HeadRow: Decodable, Sendable, Equatable, Identifiable {
        public struct Tag: Decodable, Sendable, Equatable {
            public let vendor: String
            public let manufacturer: String
            public let material: String
            public let sub: String
            public let colours: [String]
            public let weightG: Double?
            public let diameterMm: Double?
        }
        public struct Live: Decodable, Sendable, Equatable {
            public let hex: String
            public let material: String
        }
        public struct Prefill: Decodable, Sendable, Equatable {
            public let material: String
            public let color: String?
            public let brand: String?
            public let weight: Double?
        }
        /// From zero, as the book keys `headSpools`. People are shown `head + 1`.
        public let head: Int
        /// What the head's spool tag says; nil with no tag.
        public let tag: Tag?
        /// What the printer itself says is loaded, with or without a tag.
        public let live: Live?
        /// The dot's colour: the tag's, else the printer's, else the linked spool's. "" for none.
        public let hex: String
        /// The spool recorded in this head, when it is still on the shelf.
        public let spoolId: String?
        /// `link`, `ask`, `new` or `none`: the shared rule's answer for what is in the head.
        public let match: String
        /// The spools to offer, best first (one for `link`).
        public let candidates: [String]
        /// What "Add as a new spool" would add. Only from a TAG: a printer's own
        /// word for what is loaded is not enough to make a spool from.
        public let prefill: Prefill?
        /// The head's own nozzle size, when the printer reports it per extruder; nil
        /// today (the machine's is used). A data change, not a redesign, when it does.
        public var nozzleMm: Double? = nil
        public var id: Int { head }
    }

    /// One row per head: at least four, and as many as the tags or the
    /// printer's own report name (sixteen at most).
    ///
    /// - `filamentDetect`: the printer's `filament_detect`, or `.null`.
    /// - `loaded`: what the printer reports loaded, `[{slot, hex, material}]`.
    /// - `spools`: the shop's `inventory` records, raw.
    /// - `linked`: the machine's `headSpools`, or `.null`.
    public func machineHeads(filamentDetect: JSONValue, loaded: JSONValue, spools: [JSONValue], linked: JSONValue = .null) throws -> [HeadRow] {
        try runtime.call2("""
            (function (detect, loaded, spools, linked) {
              var RT = globalThis.KhaytRfidTray, LC = globalThis.KhaytLoadedColours;
              var shelf = (Array.isArray(spools) ? spools : []).filter(function (s) { return s && s.id != null && !s.deleted; });
              var tags = detect ? RT.trays(detect) : [];
              var live = LC && typeof LC.normalizeLoaded === 'function' ? LC.normalizeLoaded(loaded) : [];
              var held = linked && typeof linked === 'object' && !Array.isArray(linked) ? linked : {};
              var top = live.length ? Math.max.apply(null, live.map(function (l) { return l.slot; })) + 1 : 0;
              var count = Math.min(Math.max(4, tags.length, top), 16);
              var rows = [];
              for (var i = 0; i < count; i++) {
                var tag = tags[i] || null;
                var slot = null;
                for (var k = 0; k < live.length; k++) if (live[k].slot === i) slot = live[k];
                var id = Object.prototype.hasOwnProperty.call(held, String(i)) ? held[String(i)] : null;
                var spool = null;
                if (id != null) for (var j = 0; j < shelf.length; j++) if (String(shelf[j].id) === String(id)) spool = shelf[j];
                // What is in the head, for matching: the tag, else the printer's own word for it.
                var tray = tag && tag.material ? tag
                  : (slot && slot.material ? { material: String(slot.material).split(' ')[0], sub: '', colours: slot.hex ? [slot.hex] : [], manufacturer: '', vendor: '' } : null);
                var m = tray ? RT.spoolMatch(tray, shelf) : { action: 'none' };
                // The one strong match first, then the near ones: the rule asked again without it (as for a phone).
                var offered = [];
                if (m.action === 'link') {
                  var rest = RT.spoolMatch(tray, shelf.filter(function (s) { return String(s.id) !== String(m.spoolId); }));
                  offered = [m.spoolId].concat(rest.action === 'link' ? [rest.spoolId] : (rest.action === 'ask' ? rest.candidates.map(function (c) { return c.spoolId; }) : []));
                } else if (m.action === 'ask') offered = m.candidates.map(function (c) { return c.spoolId; });
                var p = tag ? (RT.spoolMatch(tag, []).prefill || null) : null;
                rows.push({
                  head: i,
                  tag: tag ? { vendor: tag.vendor || '', manufacturer: tag.manufacturer || '', material: tag.material || '', sub: tag.sub || '',
                               colours: tag.colours || [], weightG: tag.weightG, diameterMm: tag.diameterMm } : null,
                  live: slot ? { hex: slot.hex || '', material: slot.material || '' } : null,
                  hex: (tag && tag.colours && tag.colours[0]) || (slot && slot.hex) || (spool && typeof spool.color === 'string' && spool.color) || '',
                  spoolId: spool ? String(spool.id) : null,
                  match: m.action,
                  candidates: offered,
                  prefill: p ? { material: p.material, color: p.color, brand: p.brand, weight: p.weight } : null
                });
              }
              return rows;
            })(ARG0, ARG1, ARG2, ARG3)
            """, [filamentDetect, loaded, .array(spools), linked], as: [HeadRow].self)
    }
}
