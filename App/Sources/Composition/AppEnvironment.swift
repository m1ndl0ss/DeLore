import DeLoreCore
import DeLoreFakes
import Foundation

/// Composition root: builds every dependency once and hands out narrow interfaces.
@MainActor
final class AppEnvironment {
    enum DataMode: Equatable {
        /// The user's own Instagram download, processed on device.
        case instagramExport
        /// Built-in sample chats for internal builds and UI tests. Never talks to Instagram.
        case sampleData
    }

    let configuration: AppConfiguration
    let logger: AppLogger
    let analytics: Analytics
    let secrets: SecretStore
    let jobStore: JobStore
    let library: LocalLibraryStore
    let sessionVault: SessionVault
    let entitlements: EntitlementManager
    let connectivity: ConnectivityMonitor
    let isUITesting: Bool
    private let liveUnsender: UnsendService
    private let dataDirectory: URL

    private(set) var dataMode: DataMode
    private var sampleService: FakeInstagramService?

    private static let sampleModeKey = "sampleData.enabled"
    private static let onboardingKey = "onboarding.completed"

    init(configuration: AppConfiguration = .load(), arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.configuration = configuration
        #if DEBUG
        isUITesting = arguments.contains("-uitesting")
        if isUITesting, let domain = Bundle.main.bundleIdentifier {
            // Every UI test starts from a fresh install state.
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        #else
        isUITesting = false
        #endif

        let subsystem = Bundle.main.bundleIdentifier ?? "app.delore.ios"
        logger = AppLogger.make(subsystem: subsystem)
        // No third-party SDK: the sink is a no-op until a privacy-preserving backend is wired.
        analytics = Analytics(sink: NoopAnalyticsSink(), isEnabled: configuration.analyticsEnabled)

        let fileManager = FileManager.default
        let baseDirectory: URL
        if isUITesting {
            baseDirectory = fileManager.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)", isDirectory: true)
            secrets = InMemorySecretStore()
        } else {
            baseDirectory = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory).appendingPathComponent("DeLore", isDirectory: true)
            secrets = KeychainSecretStore(service: subsystem)
        }
        dataDirectory = baseDirectory
        try? ProtectedFiles.prepareDirectory(baseDirectory)

        library = LocalLibraryStore(root: baseDirectory.appendingPathComponent("library", isDirectory: true))
        do {
            jobStore = try FileJobStore(root: baseDirectory.appendingPathComponent("jobs", isDirectory: true))
        } catch {
            // Storage unavailable (e.g. disk full). Fall back to memory so the app still opens;
            // the engine refuses to send anything it can't persist.
            logger.error("storage setup failed: \(error.safeDescription)")
            jobStore = InMemoryJobStore()
        }

        sessionVault = SessionVault(store: secrets)
        liveUnsender = LiveIntegration.makeUnsendService(sessionVault: sessionVault, logger: logger)
        connectivity = ConnectivityMonitor()

        let ledger = PassLedger(store: secrets)
        let purchaseService: PurchaseService
        #if DEBUG
        if isUITesting || arguments.contains("-mockPurchases") {
            purchaseService = MockPurchaseService(ledger: ledger)
        } else {
            purchaseService = StoreKitPurchaseService(catalog: configuration.products, ledger: ledger, logger: logger)
        }
        #else
        purchaseService = StoreKitPurchaseService(catalog: configuration.products, ledger: ledger, logger: logger)
        #endif
        entitlements = EntitlementManager(
            service: purchaseService,
            ledger: ledger,
            freeLimit: configuration.freeCleanupLimit,
            analytics: analytics
        )

        dataMode = .instagramExport
        if configuration.features.sampleDataMode, UserDefaults.standard.bool(forKey: Self.sampleModeKey), !isUITesting {
            enableSampleData()
        }
    }

    // MARK: Integration

    var messageSource: MessageSource {
        if dataMode == .sampleData, let sampleService { return sampleService }
        return library
    }

    var unsender: UnsendService {
        if dataMode == .sampleData, let sampleService { return sampleService }
        return liveUnsender
    }

    /// Whether unsending can actually run in this build and mode.
    var isCleanupAvailable: Bool {
        dataMode == .sampleData || !(liveUnsender is UnavailableUnsendService)
    }

    var ratePolicy: RatePolicy {
        guard dataMode == .sampleData else { return configuration.ratePolicy }
        if isUITesting {
            var instant = RatePolicy.demo
            instant.minimumDelay = 0
            instant.maximumJitter = 0.01
            return instant
        }
        return .demo
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

    func enableSampleData() {
        guard configuration.features.sampleDataMode else { return }
        sampleService = FakeInstagramService.demo(latency: isUITesting ? 0 : 0.12)
        dataMode = .sampleData
        if !isUITesting { UserDefaults.standard.set(true, forKey: Self.sampleModeKey) }
    }

    private func disableSampleData() {
        sampleService = nil
        dataMode = .instagramExport
        UserDefaults.standard.removeObject(forKey: Self.sampleModeKey)
    }

    // MARK: Library

    var hasLibrary: Bool {
        dataMode == .sampleData || library.hasLibrary
    }

    func loadOverview() async throws -> LibraryOverview {
        switch dataMode {
        case .sampleData:
            return LibraryOverview(conversations: try await messageSource.conversations())
        case .instagramExport:
            let cleaned = try jobStore.loadLedger()
            return try await library.overview(excluding: cleaned)
        }
    }

    // MARK: Onboarding

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingKey) }
    }

    // MARK: Erase

    /// Disconnects and removes everything sensitive. Purchases (unused passes, free usage)
    /// are kept because they belong to the user, and aren't sensitive.
    func eraseAllData() throws {
        disableSampleData()
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
