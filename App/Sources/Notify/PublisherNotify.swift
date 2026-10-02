import Foundation

/// Fire-and-forget ops ping to the publisher notify worker.
/// Empty `DLNotifyURL` / secret = no-op. Never blocks login or purchase UI.
@MainActor
final class PublisherNotify {
    private let defaults: UserDefaults
    private let isEnabled: () -> Bool
    private let resolveUsername: () -> String?
    private let endpoint: String
    private let secret: String

    init(
        defaults: UserDefaults = .standard,
        endpoint: String,
        secret: String,
        isEnabled: @escaping () -> Bool,
        resolveUsername: @escaping () -> String?
    ) {
        self.defaults = defaults
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.resolveUsername = resolveUsername
    }

    func instagramConnected(userID: String, username: String) {
        guard let handle = Self.clean(username) else { return }
        postOnce(
            prefKey: "notify.connect.\(userID)",
            event: "instagram_connected",
            username: handle,
            productID: nil,
            promoCode: nil,
            idempotencyKey: "connect:\(userID)"
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
        guard !endpoint.isEmpty, !secret.isEmpty, let url = URL(string: endpoint) else { return }

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

        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(secret, forHTTPHeaderField: "X-Retract-Secret")
        request.httpBody = body

        Task.detached(priority: .utility) { [defaults] in
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
}
