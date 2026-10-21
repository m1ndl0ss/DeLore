import Foundation

/// Mints short-lived bearer tokens from the Retract worker. The signing key never ships in the app.
final class WorkerAuth: @unchecked Sendable {
    private let notifyURL: String
    private let lock = NSLock()
    private var token: String?
    private var expiresAt: Date = .distantPast

    init(notifyURL: String) {
        self.notifyURL = notifyURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Base origin derived from `…/v1/notify` (or any `/v1/…` path).
    var baseURL: URL? {
        guard !notifyURL.isEmpty, var components = URLComponents(string: notifyURL) else { return nil }
        let path = components.path
        if let range = path.range(of: "/v1/") {
            components.path = String(path[..<range.lowerBound])
        } else if path.hasSuffix("/notify") {
            components.path = String(path.dropLast("/notify".count))
        }
        // Ensure we have a usable base (host + optional empty path).
        if components.path.isEmpty { components.path = "" }
        return components.url
    }

    func url(path: String) -> URL? {
        guard let base = baseURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + clean
        return components?.url
    }

    func bearerToken() async -> String? {
        lock.lock()
        if let token, expiresAt.timeIntervalSinceNow > 60 {
            lock.unlock()
            return token
        }
        lock.unlock()

        guard let url = url(path: "v1/token") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String,
                  let exp = json["expiresAt"] as? TimeInterval
            else { return nil }
            lock.lock()
            self.token = token
            self.expiresAt = Date(timeIntervalSince1970: exp)
            lock.unlock()
            return token
        } catch {
            return nil
        }
    }
}
