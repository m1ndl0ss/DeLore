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
        if body.isEmpty {
            return destructive ? .unexpectedResponse(code: statusCode) : nil
        }
        let stripped = stripJsEnvelope(body)
        guard let object = try? JSONSerialization.jsonObject(with: stripped) as? [String: Any] else {
            if looksLikeHTML(stripped) || looksLikeHTML(body) {
                let html = String(data: stripped.prefix(4_000), encoding: .utf8)?.lowercased() ?? ""
                if html.contains("checkpoint") || html.contains("/challenge") { return .verificationRequired }
                if html.contains("/accounts/login") || html.contains("login_required") { return .sessionExpired }
                return .unexpectedResponse(code: statusCode)
            }
            return destructive ? .unexpectedResponse(code: statusCode) : nil
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
        if let data = object["data"] as? [String: Any], boolish(data["direct_unsend_message"]) {
            return nil
        }
        if object["errors"] != nil && object["inbox"] == nil && object["thread"] == nil {
            return .unexpectedResponse(code: nil)
        }
        if status == "fail" || status == "error" {
            if envelope.contains("not found") || envelope.contains("does not exist") || envelope.contains("no longer") || envelope.contains("already") {
                return nil
            }
            return .unexpectedResponse(code: nil)
        }
        return destructive ? .unexpectedResponse(code: statusCode) : nil
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

    static func boolish(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return text.lowercased() == "true" || text == "1"
        default: return false
        }
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(200), encoding: .utf8)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return prefix.contains("<!doctype") || prefix.contains("<html") || prefix.contains("<head") || prefix.hasPrefix("<script") || prefix.hasPrefix("<!--")
    }

    static func stripJsEnvelope(_ body: Data) -> Data {
        guard var text = String(data: body, encoding: .utf8) else { return body }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["for (;;);", "while(1);", "while (1);", ")]}',", ")]}'"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return Data(text.utf8)
    }
}

/// Success payload for a delete/unsend. `ok` and "already gone" are both terminal successes.
public enum InstagramDeleteParse {
    public static func outcome(from response: HTTPResponse) throws -> UnsendOutcome {
        let stripped = InstagramResponseClassifier.stripJsEnvelope(response.body)
        guard let object = (try? JSONSerialization.jsonObject(with: stripped)) as? [String: Any] else {
            throw IntegrationError.unexpectedResponse(code: response.statusCode)
        }
        if let data = object["data"] as? [String: Any], InstagramResponseClassifier.boolish(data["direct_unsend_message"]) {
            return .unsent
        }
        let blob = (object["message"] as? String ?? "").lowercased()
            + (object["error_title"] as? String ?? "").lowercased()
        if blob.contains("not found") || blob.contains("already") || blob.contains("no longer") {
            return .alreadyGone
        }
        let status = (object["status"] as? String)?.lowercased() ?? ""
        if status == "ok" || status == "success" { return .unsent }
        throw IntegrationError.unexpectedResponse(code: response.statusCode)
    }
}
