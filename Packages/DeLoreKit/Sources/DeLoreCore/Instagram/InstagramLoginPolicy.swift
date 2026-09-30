import Foundation

/// Hosts Instagram's own login page is allowed to load. Everything else is blocked.
/// Facebook/Meta hosts are included only because Instagram's sign-in uses them for SSO.
public enum InstagramLoginPolicy {
    public static let allowedHostSuffixes = [
        "instagram.com",
        "cdninstagram.com",
        "facebook.com",
        "fbcdn.net",
        "facebook.net",
        "meta.com",
        "accountkit.com"
    ]

    public static func allowsNavigation(to url: URL) -> Bool {
        if let scheme = url.scheme?.lowercased(), scheme == "about" { return true }
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public static func isInstagramCookieDomain(_ domain: String) -> Bool {
        let trimmed = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed == "instagram.com" || trimmed.hasSuffix(".instagram.com")
    }

    public static func isPostLogin(url: URL) -> Bool {
        guard allowsNavigation(to: url) else { return false }
        let path = url.path.lowercased()
        if path.contains("/accounts/login") { return false }
        if path.contains("/accounts/emailsignup") { return false }
        if path.contains("/challenge") { return false }
        if path.contains("/two_factor") { return false }
        if path.contains("/accounts/password") { return false }
        return true
    }

    public static func isDirectSurface(url: URL) -> Bool {
        guard allowsNavigation(to: url) else { return false }
        return url.path.lowercased().hasPrefix("/direct/")
    }
}
