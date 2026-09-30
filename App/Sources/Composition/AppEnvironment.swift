import DeLoreCore
import Foundation

/// Composition root: builds every dependency once and hands out narrow interfaces.
@MainActor
final class AppEnvironment {
    let configuration: AppConfiguration
    let logger: AppLogger
    let analytics: Analytics
    let secrets: SecretStore
    let jobStore: JobStore
    let library: LocalLibraryStore
    let sessionVault: SessionVault
    let history: CleanupHistoryStore
    let entitlements: EntitlementManager
    let connectivity: ConnectivityMonitor
    private let liveUnsender: UnsendService
    private let dataDirectory: URL

    private static let onboardingKey = "onboarding.completed"
    private static let inboxHoldOffKey = "inbox.holdOffUntil"
    private static let listFirstKey = "inbox.listFirst"

    init(configuration: AppConfiguration = .load()) {
        self.configuration = configuration

        let subsystem = Bundle.main.bundleIdentifier ?? "app.delore.ios"
        logger = AppLogger.make(subsystem: subsystem)
        analytics = Analytics(sink: NoopAnalyticsSink(), isEnabled: configuration.analyticsEnabled)

        let fileManager = FileManager.default
        let baseDirectory = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory).appendingPathComponent("Retract", isDirectory: true)
        dataDirectory = baseDirectory
        secrets = KeychainSecretStore(service: subsystem)
        try? ProtectedFiles.prepareDirectory(baseDirectory)

        library = LocalLibraryStore(root: baseDirectory.appendingPathComponent("library", isDirectory: true))
        do {
            jobStore = try FileJobStore(root: baseDirectory.appendingPathComponent("jobs", isDirectory: true))
        } catch {
            logger.error("storage setup failed: \(error.safeDescription)")
            jobStore = InMemoryJobStore()
        }

        sessionVault = SessionVault(store: secrets)
        do {
            history = try FileCleanupHistoryStore(root: baseDirectory.appendingPathComponent("history", isDirectory: true))
        } catch {
            logger.error("history setup failed: \(error.safeDescription)")
            history = InMemoryCleanupHistoryStore()
        }
        liveUnsender = LiveIntegration.makeUnsendService(sessionVault: sessionVault, logger: logger)
        connectivity = ConnectivityMonitor()

        let ledger = PassLedger(store: secrets)
        entitlements = EntitlementManager(
            service: StoreKitPurchaseService(catalog: configuration.products, ledger: ledger, logger: logger),
            ledger: ledger,
            freeLimit: configuration.freeCleanupLimit,
            analytics: analytics
        )
    }

    var messageSource: MessageSource { library }
    var unsender: UnsendService { liveUnsender }
    var isCleanupAvailable: Bool { hasLiveSession }
    var ratePolicy: RatePolicy { configuration.ratePolicy }

    var hasLiveSession: Bool {
        (try? sessionVault.loadSession())?.hasLiveSession == true
    }

    func saveInstagramSession(_ session: InstagramWebSession) throws {
        try sessionVault.saveSession(session)
    }

    func listInbox(onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil) async throws -> LibraryOverview {
        guard let session = try sessionVault.loadSession(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        let sync = LiveIntegration.makeInboxSync(sessionVault: sessionVault, library: library, logger: logger)
        return try await Task.detached(priority: .userInitiated) {
            try await sync.list(session: session, onProgress: onProgress)
        }.value
    }

    func loadInbox(ids: [ConversationID], onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil) async throws -> LibraryOverview {
        guard let session = try sessionVault.loadSession(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        let sync = LiveIntegration.makeInboxSync(sessionVault: sessionVault, library: library, logger: logger)
        return try await Task.detached(priority: .userInitiated) {
            try await sync.load(session: session, ids: ids, onProgress: onProgress)
        }.value
    }

    func engineDependencies() -> CleanupEngineDependencies {
        CleanupEngineDependencies(
            store: jobStore,
            unsender: unsender,
            policy: ratePolicy,
            analytics: analytics,
            logger: logger,
            history: history
        )
    }

    var hasLibrary: Bool { library.hasLibrary }

    func loadOverview() async throws -> LibraryOverview {
        let cleaned = try jobStore.loadLedger()
        return try await library.overview(excluding: cleaned)
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingKey) }
    }

    var inboxHoldOffUntil: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: Self.inboxHoldOffKey)
            guard value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.inboxHoldOffKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.inboxHoldOffKey)
            }
        }
    }

    var isInboxOnHold: Bool {
        guard let until = inboxHoldOffUntil else { return false }
        return until > Date()
    }

    func dropStaleFullInbox() {
        guard !UserDefaults.standard.bool(forKey: Self.listFirstKey) else { return }
        try? library.wipe()
        try? jobStore.wipe()
        UserDefaults.standard.set(true, forKey: Self.listFirstKey)
    }

    /// Disconnects and removes everything sensitive. Purchases (unused passes, free usage)
    /// are kept because they belong to the user, and aren't sensitive.
    func eraseAllData() throws {
        let eraser = LocalDataEraser(
            secrets: secrets,
            jobs: jobStore,
            library: library,
            preservedSecretKeys: PassLedger.preservedKeys
        )
        try history.wipe()
        try eraser.eraseAll()
        UserDefaults.standard.removeObject(forKey: Self.onboardingKey)
        UserDefaults.standard.removeObject(forKey: Self.inboxHoldOffKey)
        UserDefaults.standard.removeObject(forKey: Self.listFirstKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(CleanupBilling.keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        analytics.track(.dataErased)
    }
}
