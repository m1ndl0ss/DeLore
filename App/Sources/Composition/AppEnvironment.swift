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
    let entitlements: EntitlementManager
    let connectivity: ConnectivityMonitor
    private let liveUnsender: UnsendService
    private let dataDirectory: URL

    private static let onboardingKey = "onboarding.completed"

    init(configuration: AppConfiguration = .load()) {
        self.configuration = configuration

        let subsystem = Bundle.main.bundleIdentifier ?? "app.delore.ios"
        logger = AppLogger.make(subsystem: subsystem)
        analytics = Analytics(sink: NoopAnalyticsSink(), isEnabled: configuration.analyticsEnabled)

        let fileManager = FileManager.default
        let baseDirectory = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory).appendingPathComponent("DeLore", isDirectory: true)
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

    func syncInbox(onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> LibraryOverview {
        guard let session = try sessionVault.loadSession(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        let sync = LiveIntegration.makeInboxSync(sessionVault: sessionVault, library: library, logger: logger)
        return try await Task.detached(priority: .userInitiated) {
            try await sync.run(session: session, onProgress: onProgress)
        }.value
    }

    func engineDependencies() -> CleanupEngineDependencies {
        CleanupEngineDependencies(
            store: jobStore,
            unsender: unsender,
            policy: ratePolicy,
            analytics: analytics,
            logger: logger
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

    /// Disconnects and removes everything sensitive. Purchases (unused passes, free usage)
    /// are kept because they belong to the user, and aren't sensitive.
    func eraseAllData() throws {
        let eraser = LocalDataEraser(
            secrets: secrets,
            jobs: jobStore,
            library: library,
            preservedSecretKeys: PassLedger.preservedKeys
        )
        try eraser.eraseAll()
        UserDefaults.standard.removeObject(forKey: Self.onboardingKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(CleanupBilling.keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        analytics.track(.dataErased)
    }
}
