import Foundation

/// Fire-and-forget ops ping to the publisher notify worker.
/// Empty `DLNotifyURL` = no-op. Auth is a short-lived worker token (no secret in the app).
@MainActor
final class PublisherNotify {
    private let defaults: UserDefaults
    private let isEnabled: () -> Bool
    private let resolveUsername: () -> String?
    private let auth: WorkerAuth

    init(
        defaults: UserDefaults = .standard,
        endpoint: String,
        isEnabled: @escaping () -> Bool,
        resolveUsername: @escaping () -> String?
    ) {
        self.defaults = defaults
        self.auth = WorkerAuth(notifyURL: endpoint)
        self.isEnabled = isEnabled
        self.resolveUsername = resolveUsername
    }

    var workerAuth: WorkerAuth { auth }

    func instagramConnected(userID: String, username: String) {
        guard let handle = Self.clean(username) else { return }
        postOnce(
            prefKey: "notify.connect.\(userID)",
            event: "instagram_connected",
            username: handle,
            productID: nil,
            promoCode: nil,
            idempotencyKey: "connect:\(userID):\(Self.dayStamp())"
        )
    }

    func subscriptionPurchased(
        username: String?,
        productID: String,
        promoCode: String?,
        transactionID: String
    ) {
        guard let handle = Self.clean(username ?? resolveUsername()) else { return }
        postOnce(
            prefKey: "notify.purchase.\(transactionID)",
            event: "subscription_purchased",
            username: handle,
            productID: productID,
            promoCode: promoCode,
            idempotencyKey: "purchase:\(transactionID)"
        )
    }

    func complimentaryUnlocked(userID: String?, username: String?, promoCode: String) {
        guard let handle = Self.clean(username ?? resolveUsername()) else { return }
        let id = userID ?? handle
        postOnce(
            prefKey: "notify.comp.\(id).\(promoCode)",
            event: "complimentary_unlocked",
            username: handle,
            productID: nil,
            promoCode: promoCode,
            idempotencyKey: "comp:\(id):\(promoCode)"
        )
    }

    private func postOnce(
        prefKey: String,
        event: String,
        username: String,
        productID: String?,
        promoCode: String?,
        idempotencyKey: String
    ) {
        guard isEnabled() else { return }
        guard !defaults.bool(forKey: prefKey) else { return }
        guard auth.baseURL != nil else {
            #if DEBUG
            print("Retract notify skipped: DLNotifyURL empty (see Config/Secrets.xcconfig)")
            #endif
            return
        }

        defaults.set(true, forKey: prefKey)

        var payload: [String: Any] = [
            "event": event,
            "instagramUsername": username,
            "platform": "ios",
            "occurredAt": ISO8601DateFormatter().string(from: Date()),
            "idempotencyKey": idempotencyKey,
        ]
        if let productID, !productID.isEmpty { payload["productId"] = productID }
        if let promoCode, !promoCode.isEmpty { payload["promoCode"] = promoCode }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            defaults.set(false, forKey: prefKey)
            return
        }

        let auth = self.auth
        Task.detached(priority: .utility) { [defaults] in
            guard let url = auth.url(path: "v1/notify"),
                  let token = await auth.bearerToken()
            else {
                await MainActor.run { defaults.set(false, forKey: prefKey) }
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 2.5)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if !(200...299).contains(code) {
                    await MainActor.run { defaults.set(false, forKey: prefKey) }
                }
            } catch {
                await MainActor.run { defaults.set(false, forKey: prefKey) }
            }
        }
    }

    static func clean(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        while trimmed.hasPrefix("@") { trimmed.removeFirst() }
        guard !trimmed.isEmpty, trimmed.lowercased() != "you" else { return nil }
        guard trimmed.count <= 64,
              trimmed.range(of: #"^[A-Za-z0-9._]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func dayStamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
