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
    let publisherNotify: PublisherNotify
    private let liveUnsender: UnsendService
    private let demoUnsender = ReviewDemoUnsendService()
    private let dataDirectory: URL

    private static let onboardingKey = "onboarding.completed"
    private static let termsVersionKey = "terms.acceptedVersion"
    private static let inboxHoldOffKey = "inbox.holdOffUntil"
    private static let listFirstKey = "inbox.listFirst"
    private static let listCursorKey = "inbox.listCursor"
    private static let inboxWorkKey = "inbox.work"
    private static let retractQueueKey = "inbox.retractQueue"
    private static let reviewDemoKey = "review.demo"

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

        let vault = sessionVault
        let notify = PublisherNotify(
            endpoint: configuration.notifyURL,
            secret: configuration.notifySecret,
            isEnabled: { !UserDefaults.standard.bool(forKey: Self.reviewDemoKey) },
            resolveUsername: {
                (try? vault.loadSession())?.displayName
            }
        )
        publisherNotify = notify

        let ledger = PassLedger(store: secrets)
        entitlements = EntitlementManager(
            service: StoreKitPurchaseService(catalog: configuration.products, ledger: ledger, logger: logger),
            ledger: ledger,
            freeLimit: configuration.freeCleanupLimit,
            analytics: analytics,
            onSubscriptionPurchased: { productID, promo in
                let session = try? vault.loadSession()
                notify.subscriptionPurchased(
                    username: session?.displayName,
                    productID: productID,
                    promoCode: promo,
                    transactionID: "buy:\(productID):\(session?.userID ?? "anon")"
                )
            },
            onComplimentaryUnlocked: { code in
                let session = try? vault.loadSession()
                notify.complimentaryUnlocked(
                    userID: session?.userID,
                    username: session?.displayName,
                    promoCode: code
                )
            }
        )
    }

    var messageSource: MessageSource { library }
    var unsender: UnsendService { isDemoMode ? demoUnsender : liveUnsender }
    var isCleanupAvailable: Bool { hasLiveSession || isDemoMode }
    var ratePolicy: RatePolicy { isDemoMode ? .review : configuration.ratePolicy }

    var hasLiveSession: Bool {
        (try? sessionVault.loadSession())?.hasLiveSession == true
    }

    var isDemoMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.reviewDemoKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.reviewDemoKey) }
    }

    func enterReviewDemo() throws {
        try jobStore.wipe()
        try ReviewDemo.seed(into: library)
        saveRetractQueue([])
        saveInboxWork(nil)
        inboxListCursor = nil
        isDemoMode = true
    }

    func clearReviewDemoFlag() {
        isDemoMode = false
    }

    func saveInstagramSession(_ session: InstagramWebSession) throws {
        clearReviewDemoFlag()
        try sessionVault.saveSession(session)
    }

    func listInbox(onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil) async throws -> LibraryOverview {
        guard let session = try sessionVault.loadSession(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        let resume = inboxListCursor
        let cursorKey = Self.listCursorKey
        let sync = LiveIntegration.makeInboxSync(sessionVault: sessionVault, library: library, logger: logger)
        let overview = try await Task.detached(priority: .userInitiated) {
            try await sync.list(session: session, resumeCursor: resume, onProgress: onProgress) { cursor in
                if let cursor, !cursor.isEmpty {
                    UserDefaults.standard.set(cursor, forKey: cursorKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: cursorKey)
                }
            }
        }.value
        await maybeNotifyConnected()
        return overview
    }

    func loadInbox(
        ids: [ConversationID],
        titles: [String: String] = [:],
        forceRefresh: Bool = false,
        onProgress: (@Sendable (InboxReadProgress) -> Void)? = nil
    ) async throws -> LibraryOverview {
        guard let session = try sessionVault.loadSession(), session.hasLiveSession else {
            throw IntegrationError.sessionExpired
        }
        let sync = LiveIntegration.makeInboxSync(sessionVault: sessionVault, library: library, logger: logger)
        let overview = try await Task.detached(priority: .userInitiated) {
            try await sync.load(
                session: session,
                ids: ids,
                titles: titles,
                forceRefresh: forceRefresh,
                onProgress: onProgress
            )
        }.value
        await maybeNotifyConnected()
        return overview
    }

    private func maybeNotifyConnected() async {
        guard !isDemoMode else { return }
        guard var session = try? sessionVault.loadSession(), session.hasLiveSession else { return }
        let fromLibrary = try? await library.account().displayName
        guard let username = PublisherNotify.clean(session.displayName)
            ?? PublisherNotify.clean(fromLibrary) else { return }
        if session.displayName == nil || session.displayName == "you" {
            session.displayName = username
            try? sessionVault.saveSession(session)
        }
        publisherNotify.instagramConnected(userID: session.userID, username: username)
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

    var acceptedTermsVersion: Int {
        get { UserDefaults.standard.integer(forKey: Self.termsVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.termsVersionKey) }
    }

    var hasAcceptedTerms: Bool { acceptedTermsVersion >= LegalCopy.termsVersion }

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

    var inboxListCursor: String? {
        get {
            let value = UserDefaults.standard.string(forKey: Self.listCursorKey)
            return value?.isEmpty == false ? value : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: Self.listCursorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.listCursorKey)
            }
        }
    }

    func dropStaleFullInbox() {
        guard !isDemoMode else { return }
        guard !UserDefaults.standard.bool(forKey: Self.listFirstKey) else { return }
        try? library.wipe()
        try? jobStore.wipe()
        UserDefaults.standard.set(true, forKey: Self.listFirstKey)
        UserDefaults.standard.removeObject(forKey: Self.listCursorKey)
        UserDefaults.standard.removeObject(forKey: Self.inboxWorkKey)
    }

    func saveInboxWork(_ snapshot: InboxWorkSnapshot?) {
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.inboxWorkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.inboxWorkKey)
        }
    }

    func loadInboxWork() -> InboxWorkSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: Self.inboxWorkKey) else { return nil }
        return try? JSONDecoder().decode(InboxWorkSnapshot.self, from: data)
    }

    func saveRetractQueue(_ ids: Set<ConversationID>) {
        let raw = ids.map(\.rawValue)
        if raw.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.retractQueueKey)
        } else if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.retractQueueKey)
        }
    }

    func loadRetractQueue() -> Set<ConversationID> {
        guard let data = UserDefaults.standard.data(forKey: Self.retractQueueKey),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(raw.map(ConversationID.init))
    }

    /// Disconnects and removes everything sensitive. Purchases (unused passes, free usage)
    /// are kept because they belong to the user, and aren't sensitive.
    func eraseAllData() throws {
        let eraser = LocalDataEraser(
            secrets: secrets,
            jobs: jobStore,
            library: library,
            preservedSecretKeys: PassLedger.preservedKeys + [PromoVault.complimentaryKey]
        )
        try history.wipe()
        try eraser.eraseAll()
        UserDefaults.standard.removeObject(forKey: Self.onboardingKey)
        UserDefaults.standard.removeObject(forKey: Self.termsVersionKey)
        UserDefaults.standard.removeObject(forKey: Self.inboxHoldOffKey)
        UserDefaults.standard.removeObject(forKey: Self.listFirstKey)
        UserDefaults.standard.removeObject(forKey: Self.listCursorKey)
        UserDefaults.standard.removeObject(forKey: Self.inboxWorkKey)
        UserDefaults.standard.removeObject(forKey: Self.retractQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.reviewDemoKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(CleanupBilling.keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("notify.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        analytics.track(.dataErased)
    }
}
