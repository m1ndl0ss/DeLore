import Foundation

/// Classifies Instagram website responses. Looks only for platform-safety signals
/// (login, checkpoint, rate limit) — never for message content.
public enum InstagramResponseClassifier {
    public static func classify(_ response: HTTPResponse, destructive: Bool) -> IntegrationError? {
        if let fromStatus = statusError(response.statusCode, retryAfter: retryAfter(response), destructive: destructive) {
            if response.statusCode == 403 || response.statusCode == 400 {
                if let fromBody = bodyError(response.body, statusCode: response.statusCode, destructive: destructive) { return fromBody }
            }
            return fromStatus
        }
        return bodyError(response.body, statusCode: response.statusCode, destructive: destructive)
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

    private static func bodyError(_ body: Data, statusCode: Int, destructive: Bool) -> IntegrationError? {
        guard !body.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            if looksLikeHTML(body) {
                let html = String(data: body.prefix(4_000), encoding: .utf8)?.lowercased() ?? ""
                if html.contains("checkpoint") || html.contains("/challenge") { return .verificationRequired }
                if html.contains("/accounts/login") || html.contains("login_required") { return .sessionExpired }
                return .unexpectedResponse(code: statusCode)
            }
            return nil
        }
        let status = (object["status"] as? String)?.lowercased() ?? ""
        let envelope = envelopeText(object)
        if envelope.contains("checkpoint_required") || envelope.contains("challenge_required") {
            return .verificationRequired
        }
        if envelope.contains("login_required") || envelope.contains("not_logged_in") {
            return .sessionExpired
        }
        let spamFlag = boolish(object["spam"])
        let feedbackFlag = boolish(object["feedback_required"])
            || (object["message"] as? String)?.lowercased() == "feedback_required"
            || (object["error_type"] as? String)?.lowercased() == "feedback_required"
        if feedbackFlag || (spamFlag && status != "ok") {
            return .rateLimited(retryAfter: nil)
        }
        if envelope.contains("please wait a few minutes") || envelope.contains("rate limit") {
            return .rateLimited(retryAfter: nil)
        }
        if status == "ok" || status == "success" { return nil }
        if object["inbox"] != nil || object["thread"] != nil || object["items"] != nil { return nil }
        if status == "fail" || status == "error" {
            if envelope.contains("not found") || envelope.contains("does not exist") || envelope.contains("no longer") {
                return nil
            }
            return .unexpectedResponse(code: nil)
        }
        return nil
    }

    private static func envelopeText(_ object: [String: Any]) -> String {
        [
            object["status"],
            object["message"],
            object["error_type"],
            object["error_title"],
            object["error_message"],
            object["feedback_required"],
            object["spam"],
            object["checkpoint_required"],
            object["challenge_required"],
        ]
        .compactMap { value in value.map { "\($0)" } }
        .joined(separator: " ")
        .lowercased()
    }

    private static func boolish(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return text.lowercased() == "true" || text == "1"
        default: return false
        }
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(32), encoding: .utf8)?.lowercased() else { return false }
        return prefix.contains("<!doctype") || prefix.contains("<html")
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
