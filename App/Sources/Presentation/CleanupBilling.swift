import Foundation

/// How a job was paid for, remembered until the job ends so the free allowance is charged
/// only for messages actually cleaned. Not sensitive: just a job id and a plan kind.
enum CleanupBilling: String {
    case free
    case pass
    case pro

    static let keyPrefix = "cleanup.billing."

    static func record(_ billing: CleanupBilling, for jobID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(billing.rawValue, forKey: keyPrefix + jobID.uuidString)
    }

    static func billing(for jobID: UUID, defaults: UserDefaults = .standard) -> CleanupBilling? {
        defaults.string(forKey: keyPrefix + jobID.uuidString).flatMap(CleanupBilling.init(rawValue:))
    }

    static func clear(for jobID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyPrefix + jobID.uuidString)
    }
}
