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

    /// `allowsDeviceRequest(device, path, method, body, job)`: what SERVERS
    /// call. On a write to `/api/orders` or `/api/orders/<id>` the body
    /// matters: a price, a new quote, or a `status` on a job that is a quote
    /// now needs `quote:write`, whatever the route. `bodyText` is the request
    /// body as it arrived (the rule parses it as the route will, and an
    /// unreadable one is treated as pricing); `job` is the stored job the path
    /// names, or nil. For any other route both are ignored.
    public func deviceAllowsRequest(_ device: JSONValue, path: String, method: String,
                                    bodyText: String?, job: JSONValue?) throws -> DeviceAllowed {
        try runtime.call2("KhaytDeviceRoles.allowsDeviceRequest(ARG0, ARG1, ARG2, ARG3 === null ? undefined : ARG3, ARG4)",
                          [device, .string(path), .string(method), bodyText.map(JSONValue.string) ?? .null, job ?? .null],
                          as: DeviceAllowed.self)
    }

    /// The vectors' own call (`allowsRequest` by role, the body as given).
    public func deviceAllowsRequest(role: String, path: String, method: String, body: JSONValue, job: JSONValue) throws -> DeviceAllowed {
        try runtime.call2("KhaytDeviceRoles.allowsRequest(ARG0, ARG1, ARG2, ARG3, ARG4)",
                          [.string(role), .string(path), .string(method), body, job], as: DeviceAllowed.self)
    }

    /// `settableRoles(device, approverRole)`: the roles this person may set on
    /// THIS paired phone. A phone paired with the owner PIN can only be the
    /// owner, and only an owner may say so.
    public func deviceRolesSettable(on device: JSONValue, by approverRole: String) throws -> [String] {
        try runtime.call2("KhaytDeviceRoles.settableRoles(ARG0, ARG1).slice()", [device, .string(approverRole)], as: [String].self)
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
