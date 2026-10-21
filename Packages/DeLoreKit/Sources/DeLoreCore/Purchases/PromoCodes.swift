import Foundation

/// Checkout promo offer after a successful redeem.
public enum PromoOffer: Equatable, Sendable {
    case complimentary
    case percentOff(Int)
}

public enum PromoRedeemResult: Equatable, Sendable {
    case empty
    case locked
    case invalid(remaining: Int)
    case applied(PromoOffer)
}

/// Static helpers. Campaign (percent-off) codes and complimentary Instagram usernames
/// come from `PromoCampaignBook` so they can refresh from a remote list without an app update.
public enum PromoCatalog: Sendable {
    /// Shipped fallback if the remote list has never been fetched.
    public static let bakedPercentOffCodes: Set<String> = ["RETRACT10", "REF10"]
    public static let campaignPercentOff = 10

    public static let percentOffCodes: Set<String> = bakedPercentOffCodes

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Instagram usernames are compared case-insensitively without a leading `@`.
    public static func normalizeUsername(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    public static func offer(
        for raw: String,
        percentOffCodes: Set<String> = bakedPercentOffCodes,
        percentOff: Int = campaignPercentOff
    ) -> PromoOffer? {
        let code = normalize(raw)
        guard !code.isEmpty else { return nil }
        // Legacy binary gift code — permanently retired. Complimentary is username allowlist only.
        if code == "KANDAL24" { return nil }
        let percent = max(1, min(99, percentOff))
        if percentOffCodes.contains(code) { return .percentOff(percent) }
        return nil
    }

    public static func isValidUsername(_ username: String) -> Bool {
        guard (1...30).contains(username.count) else { return false }
        return username.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._")).contains($0) }
    }
}

/// Mutable campaign directory. Loads last remote snapshot from the secret store, else baked defaults.
public final class PromoCampaignBook: @unchecked Sendable {
    public static let remoteCodesKey = "promo.remote.codes"
    public static let remotePercentKey = "promo.remote.percent"
    public static let remoteComplimentaryKey = "promo.remote.complimentaryUsernames"

    private let lock = NSLock()
    private let store: SecretStore?
    private var codes: Set<String>
    private var percent: Int
    private var complimentaryUsernames: Set<String>

    public init(store: SecretStore? = nil) {
        self.store = store
        if let store, let cached = Self.loadCached(from: store) {
            codes = cached.codes
            percent = cached.percent
            complimentaryUsernames = cached.usernames
        } else {
            codes = PromoCatalog.bakedPercentOffCodes
            percent = PromoCatalog.campaignPercentOff
            complimentaryUsernames = []
        }
    }

    public var percentOffCodes: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return codes
    }

    public var percentOff: Int {
        lock.lock(); defer { lock.unlock() }
        return percent
    }

    public var complimentaryHandles: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return complimentaryUsernames
    }

    public func offer(for raw: String) -> PromoOffer? {
        lock.lock()
        let currentCodes = codes
        let currentPercent = percent
        lock.unlock()
        return PromoCatalog.offer(for: raw, percentOffCodes: currentCodes, percentOff: currentPercent)
    }

    public func isComplimentaryUsername(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let username = PromoCatalog.normalizeUsername(raw)
        guard PromoCatalog.isValidUsername(username) else { return false }
        lock.lock(); defer { lock.unlock() }
        return complimentaryUsernames.contains(username)
    }

    /// Replace the in-memory + cached campaign list. Returns false if percent-off codes are unusable.
    @discardableResult
    public func replaceCampaign(
        codes incoming: Set<String>,
        percentOff: Int,
        complimentaryUsernames incomingHandles: Set<String> = []
    ) -> Bool {
        let cleaned = Set(incoming.map(PromoCatalog.normalize).filter(Self.isValidCode))
        let percent = max(1, min(99, percentOff))
        let handles = Set(incomingHandles.map(PromoCatalog.normalizeUsername).filter(PromoCatalog.isValidUsername))
        guard !cleaned.isEmpty else { return false }
        lock.lock()
        codes = cleaned
        self.percent = percent
        complimentaryUsernames = handles
        lock.unlock()
        if let store {
            try? store.set(cleaned.sorted().joined(separator: ","), for: Self.remoteCodesKey)
            try? store.set(String(percent), for: Self.remotePercentKey)
            try? store.set(handles.sorted().joined(separator: ","), for: Self.remoteComplimentaryKey)
        }
        return true
    }

    private static func loadCached(from store: SecretStore) -> (codes: Set<String>, percent: Int, usernames: Set<String>)? {
        guard let raw = try? store.string(for: remoteCodesKey), !raw.isEmpty else { return nil }
        let codes = Set(raw.split(separator: ",").map { PromoCatalog.normalize(String($0)) }.filter(isValidCode))
        guard !codes.isEmpty else { return nil }
        let percent = Int((try? store.string(for: remotePercentKey)) ?? "") ?? PromoCatalog.campaignPercentOff
        let handlesRaw = (try? store.string(for: remoteComplimentaryKey)) ?? ""
        let usernames = Set(
            handlesRaw.split(separator: ",").map { PromoCatalog.normalizeUsername(String($0)) }.filter(PromoCatalog.isValidUsername)
        )
        return (codes, max(1, min(99, percent)), usernames)
    }

    static func isValidCode(_ code: String) -> Bool {
        guard (3...32).contains(code.count) else { return false }
        return code.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
}

/// Parses the hosted campaign JSON. Shape:
/// `{"percentOff":10,"codes":["RETRACT10","REF10"],"complimentaryUsernames":["alice"]}`
public enum RemotePromoCatalog: Sendable {
    public static let defaultURL = URL(string: "https://kandalintsev.com/r/7f3a/pc.json")!

    private struct Payload: Decodable {
        var percentOff: Int?
        var codes: [String]?
        var complimentaryUsernames: [String]?
    }

    public static func parse(_ data: Data) -> (codes: Set<String>, percent: Int, usernames: Set<String>)? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let percent = payload.percentOff ?? PromoCatalog.campaignPercentOff
        let codes = Set((payload.codes ?? []).map(PromoCatalog.normalize).filter(PromoCampaignBook.isValidCode))
        let usernames = Set((payload.complimentaryUsernames ?? []).map(PromoCatalog.normalizeUsername).filter(PromoCatalog.isValidUsername))
        guard !codes.isEmpty, (1...99).contains(percent) else { return nil }
        return (codes, percent, usernames)
    }

    /// Soft-fail fetch. Applies into `book` when the response is valid.
    @discardableResult
    public static func refresh(
        into book: PromoCampaignBook,
        from url: URL = defaultURL,
        session: URLSession = .shared
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let parsed = parse(data)
        else { return false }
        return book.replaceCampaign(
            codes: parsed.codes,
            percentOff: parsed.percent,
            complimentaryUsernames: parsed.usernames
        )
    }
}

public struct PromoVault: Sendable {
    public static let dailyLimit = 3
    public static let complimentaryKey = "promo.complimentary"
    public static let complimentaryUserKey = "promo.complimentaryUser"
    public static let complimentaryBoundKey = "promo.complimentaryBound"
    public static let percentKey = "promo.percentOff"
    public static let codeKey = "promo.appliedCode"
    public static let guessDayKey = "promo.guess.day"
    public static let guessCountKey = "promo.guess.count"
    /// Nothing complimentary is device-sticky anymore — allowlist is live from the hosted file.
    public static let preservedKeys: [String] = []

    private let store: SecretStore
    private let book: PromoCampaignBook
    private let resolve: @Sendable (String) -> PromoOffer?

    public init(
        store: SecretStore,
        book: PromoCampaignBook? = nil,
        resolve: (@Sendable (String) -> PromoOffer?)? = nil
    ) {
        self.store = store
        let resolvedBook = book ?? PromoCampaignBook(store: store)
        self.book = resolvedBook
        self.resolve = resolve ?? { resolvedBook.offer(for: $0) }
    }

    public var campaignBook: PromoCampaignBook { book }

    /// Hosted allowlist — complimentary Pro for these Instagram usernames (live, not sticky).
    public func isComplimentaryUsername(_ username: String?) -> Bool {
        book.isComplimentaryUsername(username)
    }

    public var percentOff: Int { Int((try? store.string(for: Self.percentKey)) ?? "") ?? 0 }
    public var appliedCode: String? {
        let value = (try? store.string(for: Self.codeKey))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// Clears device-local percent-off unlocks and any legacy complimentary vault flags.
    public func clearLocalUnlocks() {
        clearLegacyComplimentaryFlags()
        try? store.removeValue(for: Self.percentKey)
        try? store.removeValue(for: Self.codeKey)
    }

    /// Removes retired binary-gift vault keys. Safe to call on every refresh.
    public func clearLegacyComplimentaryFlags() {
        try? store.removeValue(for: Self.complimentaryKey)
        try? store.removeValue(for: Self.complimentaryUserKey)
        try? store.removeValue(for: Self.complimentaryBoundKey)
        if appliedCode?.uppercased() == "KANDAL24" {
            try? store.removeValue(for: Self.codeKey)
        }
    }

    public func remainingGuesses(now: Date = Date()) -> Int {
        max(0, Self.dailyLimit - guessCount(on: now))
    }

    public func isLocked(now: Date = Date()) -> Bool {
        remainingGuesses(now: now) == 0
    }

    public func redeem(_ raw: String, now: Date = Date(), accountUserID: String? = nil) -> PromoRedeemResult {
        let code = PromoCatalog.normalize(raw)
        guard !code.isEmpty else { return .empty }
        if isLocked(now: now) { return .locked }
        guard let offer = resolve(code) else {
            recordFailedGuess(now: now)
            return .invalid(remaining: remainingGuesses(now: now))
        }
        apply(offer, code: code, accountUserID: accountUserID)
        return .applied(offer)
    }

    public static func discountedPrice(_ display: String, percentOff: Int) -> String {
        guard percentOff > 0, percentOff < 100 else { return display }
        guard let match = display.range(of: #"\d+[.,]\d{1,2}|\d+"#, options: .regularExpression) else { return display }
        let token = String(display[match])
        let usesComma = token.contains(",")
        let parsed = token.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(parsed) else { return display }
        let discounted = (value * Double(100 - percentOff) / 100.0 * 100).rounded() / 100
        var formatted = String(format: "%.2f", discounted)
        if usesComma { formatted = formatted.replacingOccurrences(of: ".", with: ",") }
        return display.replacingCharacters(in: match, with: formatted)
    }

    private func apply(_ offer: PromoOffer, code: String, accountUserID: String?) {
        try? store.set(code, for: Self.codeKey)
        switch offer {
        case .complimentary:
            // Complimentary Pro is hosted allowlist only — ignore legacy redeem path.
            break
        case .percentOff(let percent):
            try? store.set(String(percent), for: Self.percentKey)
        }
    }

    private func guessCount(on date: Date) -> Int {
        let day = dayString(date)
        guard (try? store.string(for: Self.guessDayKey)) == day else { return 0 }
        return Int((try? store.string(for: Self.guessCountKey)) ?? "") ?? 0
    }

    private func recordFailedGuess(now: Date) {
        let day = dayString(now)
        let next = guessCount(on: now) + 1
        try? store.set(day, for: Self.guessDayKey)
        try? store.set(String(next), for: Self.guessCountKey)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
