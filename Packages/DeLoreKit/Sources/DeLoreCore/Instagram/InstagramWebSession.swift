import Foundation

/// A user-authenticated Instagram *website* session.
///
/// Stored only in the Keychain via `SessionVault`. Cookie values never appear in
/// `description`, `debugDescription`, or mirrors.
public struct InstagramWebSession: Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public struct Cookie: Sendable, Codable {
        public var name: String
        public var value: String
        public var domain: String
        public var path: String
        public var isSecure: Bool
        public var expiresAt: Date?

        public init(name: String, value: String, domain: String, path: String, isSecure: Bool, expiresAt: Date? = nil) {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
            self.isSecure = isSecure
            self.expiresAt = expiresAt
        }
    }

    public var cookies: [Cookie]
    /// Instagram's numeric user id (`ds_user_id`). Treat as sensitive.
    public var userID: String
    public var displayName: String?

    public init(cookies: [Cookie], userID: String, displayName: String? = nil) {
        self.cookies = cookies
        self.userID = userID
        self.displayName = displayName
    }

    public var ownerID: ParticipantID { ParticipantID("ig:" + userID) }

    public var csrfToken: String? {
        cookies.first { $0.name.caseInsensitiveCompare("csrftoken") == .orderedSame }?.value
    }

    public var wwwClaimCookie: String? {
        cookies.first { $0.name.caseInsensitiveCompare("ig_www_claim") == .orderedSame }?.value
    }

    public var hasLiveSession: Bool {
        !userID.isEmpty && cookies.contains { $0.name.caseInsensitiveCompare("sessionid") == .orderedSame && !$0.value.isEmpty }
    }

    public var account: AccountIdentity {
        AccountIdentity(ownerID: ownerID, displayName: displayName ?? "you")
    }

    /// Builds a session from cookies the Instagram login page set.
    /// Requires Instagram-domain `sessionid`, `ds_user_id`, and `csrftoken`. Facebook SSO cookies are dropped.
    public static func from(cookies: [Cookie]) -> InstagramWebSession? {
        let instagramCookies = cookies.filter {
            !$0.value.isEmpty && InstagramLoginPolicy.isInstagramCookieDomain($0.domain)
        }
        let sessionCookie = instagramCookies.first { $0.name.caseInsensitiveCompare("sessionid") == .orderedSame }
        let userCookie = instagramCookies.first { $0.name.caseInsensitiveCompare("ds_user_id") == .orderedSame }
        let csrfCookie = instagramCookies.first { $0.name.caseInsensitiveCompare("csrftoken") == .orderedSame }
        guard sessionCookie != nil, csrfCookie != nil, let userCookie else { return nil }
        return InstagramWebSession(cookies: instagramCookies, userID: userCookie.value)
    }

    /// Cookie header for Instagram HTTPS requests. Never log the return value.
    public func cookieHeader() -> Sensitive<String> {
        let value = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return Sensitive(value)
    }

    public var description: String { "InstagramWebSession(cookies: \(cookies.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["cookies": cookies.count]) }
}

public extension SessionVault {
    func saveSession(_ session: InstagramWebSession) throws {
        let data = try JSONEncoder().encode(session)
        try save(Sensitive(data))
    }

    func loadSession() throws -> InstagramWebSession? {
        guard let material = try load() else { return nil }
        return try JSONDecoder().decode(InstagramWebSession.self, from: material.value)
    }
}
