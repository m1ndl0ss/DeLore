import Foundation

/// Strips anything that looks like credentials or identifiers from free text before it can
/// reach a log line or an error description.
public enum Redactor {
    public static let placeholder = "<redacted>"

    private static let keyValuePattern: NSRegularExpression? = {
        let keys = [
            "sessionid", "session_id", "session", "csrftoken", "csrf", "ds_user_id", "ds_user", "mid", "ig_did",
            "rur", "token", "access_token", "refresh_token", "auth", "authorization", "cookie", "set-cookie",
            "password", "passwd", "pwd", "secret", "api_key", "apikey", "x-ig-www-claim", "x-csrftoken",
            "user_id", "userid", "thread_id", "item_id", "message_id", "username"
        ].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "(?i)\\b(\(keys))(\\s*[=:]\\s*|\"\\s*:\\s*\")([^\\s;,&\"]+)",
            options: []
        )
    }()

    private static let bearerPattern = try? NSRegularExpression(pattern: "(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]+")
    private static let jwtPattern = try? NSRegularExpression(pattern: "\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)?")
    /// Long opaque tokens (hex / base64 / JWT-like blobs).
    private static let opaqueTokenPattern = try? NSRegularExpression(pattern: "\\b[A-Za-z0-9_\\-]{32,}(\\.[A-Za-z0-9_\\-]{8,}){0,2}\\b")
    /// Long digit runs, which is what platform user / thread / item identifiers look like.
    private static let longNumberPattern = try? NSRegularExpression(pattern: "\\b\\d{9,}\\b")
    private static let emailPattern = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let queryPattern = try? NSRegularExpression(pattern: "\\?[^\\s]*")

    public static func redact(_ text: String) -> String {
        var result = text
        result = replace(queryPattern, in: result, with: "?" + placeholder)
        result = replace(bearerPattern, in: result, with: "Bearer " + placeholder)
        result = replace(jwtPattern, in: result, with: placeholder)
        result = replace(keyValuePattern, in: result, template: "$1$2" + placeholder)
        result = replace(emailPattern, in: result, with: placeholder)
        result = replace(opaqueTokenPattern, in: result, with: placeholder)
        result = replace(longNumberPattern, in: result, with: placeholder)
        return result
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, with replacement: String) -> String {
        replace(regex, in: text, template: NSRegularExpression.escapedTemplate(for: replacement))
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

/// Wraps a secret so it can't be printed, logged, or interpolated by accident.
public struct Sensitive<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: Value

    public init(_ value: Value) { self.value = value }

    public var description: String { Redactor.placeholder }
    public var debugDescription: String { Redactor.placeholder }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension Sensitive: Equatable where Value: Equatable {}
