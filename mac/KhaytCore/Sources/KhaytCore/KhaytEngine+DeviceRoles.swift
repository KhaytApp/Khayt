import Foundation

/// A paired phone's role and what it opens (`lib/device-roles.js`, C9; phone
/// pairing design, decided Nov 22 2026). The LAN server asks these on every
/// request a phone signs; nothing about a role is decided in Swift.
extension KhaytEngine {

    /// `allows`: whether the role may use the route, and the scope it needed.
    public struct DeviceAllowed: Decodable, Sendable, Equatable {
        public let ok: Bool
        /// The scope the route needs: one of `SCOPES`, `owner` for a route
        /// the table does not name, or nil for one any paired device may use.
        public let required: String?
        public let role: String
    }

    /// A device as the rule reads it: `kind`, `role` and `rolesVersion`
    /// exactly as stored. An absent field is absent, never an empty string.
    public static func deviceRecord(kind: String?, role: String?, rolesVersion: Int?) -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let kind { o["kind"] = .string(kind) }
        if let role { o["role"] = .string(role) }
        if let rolesVersion { o["rolesVersion"] = .number(Double(rolesVersion)) }
        return .object(o)
    }

    /// `allowsDevice(device, path, method)`. `path` is the path the router
    /// routes on (`request.path`), never the raw request line.
    public func deviceAllows(_ device: JSONValue, path: String, method: String) throws -> DeviceAllowed {
        try runtime.call2("KhaytDeviceRoles.allowsDevice(ARG0, ARG1, ARG2)", [device, .string(path), .string(method)],
                          as: DeviceAllowed.self)
    }

    /// `roleOf(device)`: the role the device holds.
    public func deviceRole(_ device: JSONValue) throws -> String {
        try runtime.call2("KhaytDeviceRoles.roleOf(ARG0)", [device], as: String.self)
    }

    /// `scopesFor(role)`.
    public func deviceScopes(role: String) throws -> [String] {
        try runtime.call2("KhaytDeviceRoles.scopesFor(ARG0).slice()", [.string(role)], as: [String].self)
    }

    /// `grantable(approverRole)`: the roles this person may give a phone
    /// (D-P3: the owner any, a manager up to manager, anyone else none).
    public func deviceRolesGrantable(by approverRole: String) throws -> [String] {
        try runtime.call2("KhaytDeviceRoles.grantable(ARG0).slice()", [.string(approverRole)], as: [String].self)
    }

    /// `DEFAULT_ROLE` (D-P2): what the approve sheet starts on.
    public func deviceDefaultRole() throws -> String {
        try runtime.call2("KhaytDeviceRoles.DEFAULT_ROLE", [], as: String.self)
    }
}
