import Foundation

/// Syncs free-unsends usage with the Retract worker (per-message increment + pull on login).
enum FreeUsageSync {
    static func pull(auth: WorkerAuth, userID: String) async -> Int? {
        await post(auth: auth, userID: userID, body: [
            "op": "pull",
            "instagramUserId": userID,
            "platform": "ios",
        ])
    }

    static func sync(auth: WorkerAuth, userID: String, localUsed: Int) async -> Int? {
        await post(auth: auth, userID: userID, body: [
            "op": "sync",
            "instagramUserId": userID,
            "freeUsed": max(0, localUsed),
            "platform": "ios",
        ])
    }

    static func increment(auth: WorkerAuth, userID: String, idempotencyKey: String) async -> Int? {
        await post(auth: auth, userID: userID, body: [
            "op": "increment",
            "instagramUserId": userID,
            "delta": 1,
            "idempotencyKey": idempotencyKey,
            "platform": "ios",
        ])
    }

    /// Deletes every server-side record for this account ("Delete my data").
    /// True only on a 2xx from the worker — callers must not wipe local state on false.
    static func deleteAll(auth: WorkerAuth, userID: String, username: String?) async -> Bool {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = auth.url(path: "v1/delete"),
              let token = await auth.bearerToken()
        else { return false }

        var body: [String: Any] = [
            "instagramUserId": userID,
            "platform": "ios",
        ]
        let handle = username?.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" })
        if let handle, !handle.isEmpty { body["instagramUsername"] = String(handle) }
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return false }

        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return false
        }
    }

    private static func post(auth: WorkerAuth, userID: String, body: [String: Any]) async -> Int? {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = auth.url(path: "v1/free-usage"),
              let token = await auth.bearerToken(),
              let payload = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (200...299).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let used = json["freeUsed"] as? Int
            else { return nil }
            return max(0, used)
        } catch {
            return nil
        }
    }
}
