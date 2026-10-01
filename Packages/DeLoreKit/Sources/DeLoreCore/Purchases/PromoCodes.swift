import Foundation

/// Checkout promo catalog. Campaign codes are 10% off; `KANDAL24` is complimentary Pro.
public enum PromoOffer: Equatable, Sendable {
    case complimentary
    case percentOff(Int)
}

public enum PromoCatalog: Sendable {
    public static let complimentaryCode = "KANDAL24"
    public static let campaignPercentOff = 10

    /// Referral codes Matvey issues. Every entry is 10% off at checkout.
    public static let percentOffCodes: Set<String> = ["RETRACT10", "REF10"]

    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public static func offer(for raw: String, percentOffCodes: Set<String> = percentOffCodes) -> PromoOffer? {
        let code = normalize(raw)
        guard !code.isEmpty else { return nil }
        if code == complimentaryCode { return .complimentary }
        if percentOffCodes.contains(code) { return .percentOff(campaignPercentOff) }
        return nil
    }
}

public enum PromoRedeemResult: Equatable, Sendable {
    case empty
    case locked
    case invalid(remaining: Int)
    case applied(PromoOffer)
}

public struct PromoVault: Sendable {
    public static let dailyLimit = 3
    public static let complimentaryKey = "promo.complimentary"
    public static let percentKey = "promo.percentOff"
    public static let codeKey = "promo.appliedCode"
    public static let guessDayKey = "promo.guess.day"
    public static let guessCountKey = "promo.guess.count"

    private let store: SecretStore
    private let resolve: @Sendable (String) -> PromoOffer?

    public init(
        store: SecretStore,
        resolve: @escaping @Sendable (String) -> PromoOffer? = { PromoCatalog.offer(for: $0) }
    ) {
        self.store = store
        self.resolve = resolve
    }

    public var isComplimentary: Bool { (try? store.string(for: Self.complimentaryKey)) == "1" }
    public var percentOff: Int { Int((try? store.string(for: Self.percentKey)) ?? "") ?? 0 }
    public var appliedCode: String? {
        let value = (try? store.string(for: Self.codeKey))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    public func remainingGuesses(now: Date = Date()) -> Int {
        max(0, Self.dailyLimit - guessCount(on: now))
    }

    public func isLocked(now: Date = Date()) -> Bool {
        remainingGuesses(now: now) == 0
    }

    public func redeem(_ raw: String, now: Date = Date()) -> PromoRedeemResult {
        let code = PromoCatalog.normalize(raw)
        guard !code.isEmpty else { return .empty }
        if isLocked(now: now) { return .locked }
        guard let offer = resolve(code) else {
            recordFailedGuess(now: now)
            return .invalid(remaining: remainingGuesses(now: now))
        }
        apply(offer, code: code)
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

    private func apply(_ offer: PromoOffer, code: String) {
        try? store.set(code, for: Self.codeKey)
        switch offer {
        case .complimentary:
            try? store.set("1", for: Self.complimentaryKey)
            try? store.removeValue(for: Self.percentKey)
        case .percentOff(let percent):
            if !isComplimentary {
                try? store.set(String(percent), for: Self.percentKey)
            }
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
