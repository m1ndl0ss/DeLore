import Foundation

/// Classifies Instagram website responses. Looks only for platform-safety signals
/// (login, checkpoint, rate limit) — never for message content.
public enum InstagramResponseClassifier {
    public static func classify(_ response: HTTPResponse, destructive: Bool) -> IntegrationError? {
        if let fromStatus = statusError(response.statusCode, retryAfter: retryAfter(response), destructive: destructive) {
            if response.statusCode == 403 || response.statusCode == 400 {
                if let fromBody = bodyError(response.body, destructive: destructive) { return fromBody }
            }
            return fromStatus
        }
        return bodyError(response.body, destructive: destructive)
    }

    public static func throwIfNeeded(_ response: HTTPResponse, destructive: Bool) throws {
        if let error = classify(response, destructive: destructive) { throw error }
    }

    private static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.header("Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) { return seconds }
        return nil
    }

    private static func statusError(_ code: Int, retryAfter: TimeInterval?, destructive: Bool) -> IntegrationError? {
        switch code {
        case 200..<300: return nil
        case 401: return .sessionExpired
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500...599: return .serverUnavailable
        case 403, 400: return .unexpectedResponse(code: code)
        default: return .unexpectedResponse(code: code)
        }
    }

    private static func bodyError(_ body: Data, destructive: Bool) -> IntegrationError? {
        guard !body.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // HTML login/checkpoint pages.
            if looksLikeHTML(body) {
                let html = String(data: body.prefix(4_000), encoding: .utf8)?.lowercased() ?? ""
                if html.contains("checkpoint") || html.contains("/challenge") { return .verificationRequired }
                if html.contains("login") { return .sessionExpired }
            }
            return nil
        }
        let blob = flattened(object).lowercased()
        if blob.contains("checkpoint_required") || blob.contains("challenge_required")
            || blob.contains("\"challenge\"") || blob.contains("/challenge/") {
            return .verificationRequired
        }
        if blob.contains("login_required") || blob.contains("not_logged_in") {
            return .sessionExpired
        }
        if blob.contains("feedback_required") || blob.contains("spam") || blob.contains("please wait a few minutes") {
            return .rateLimited(retryAfter: nil)
        }
        if blob.contains("rate limit") || blob.contains("too many") {
            return .rateLimited(retryAfter: nil)
        }
        let status = (object["status"] as? String)?.lowercased()
        if status == "fail" || status == "error" {
            if blob.contains("not found") || blob.contains("does not exist") || blob.contains("no longer") {
                return nil
            }
            return destructive ? .unexpectedResponse(code: nil) : .unexpectedResponse(code: nil)
        }
        return nil
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(32), encoding: .utf8)?.lowercased() else { return false }
        return prefix.contains("<!doctype") || prefix.contains("<html")
    }

    private static func flattened(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            return dict.keys.joined(separator: " ") + " " + dict.values.map(flattened).joined(separator: " ")
        case let array as [Any]:
            return array.prefix(20).map(flattened).joined(separator: " ")
        case let string as String:
            return string.count > 120 ? String(string.prefix(120)) : string
        default:
            return ""
        }
    }
}

/// Success payload for a delete/unsend. `ok` and "already gone" are both terminal successes.
public enum InstagramDeleteParse {
    public static func outcome(from response: HTTPResponse) -> UnsendOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return .unsent
        }
        let blob = (object["message"] as? String ?? "").lowercased()
            + (object["error_title"] as? String ?? "").lowercased()
        if blob.contains("not found") || blob.contains("already") || blob.contains("no longer") {
            return .alreadyGone
        }
        return .unsent
    }
}
