import DeLoreCore
import Foundation

enum AppEnvironmentKind: String {
    case debug, staging, release
}

/// Every tunable value in one place. Build-specific values come from `Config/*.xcconfig`
/// through Info.plist; code-level defaults live here.
struct AppConfiguration {
    let environment: AppEnvironmentKind
    let privacyPolicyURL: URL
    let supportURL: URL
    let termsURL: URL
    let products: ProductCatalog
    let freeCleanupLimit: Int
    let analyticsEnabled: Bool

    /// Official Instagram page where people request a copy of their information.
    let instagramDownloadURL = URL(string: "https://accountscenter.instagram.com/info_and_permissions/dyi/")!

    /// Pacing for destructive requests. Tune here; the engine reads every limit from it.
    let ratePolicy: RatePolicy = .conservative

    let features: FeatureFlags

    struct FeatureFlags {
        /// Sample-data mode for internal builds. Never available in Release.
        let sampleDataMode: Bool
        let advancedFilters: Bool
    }

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        func string(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        }
        func url(_ key: String, fallback: String) -> URL {
            string(key).flatMap(URL.init(string:)) ?? URL(string: fallback)!
        }

        let environment = string("DLEnvironment").flatMap(AppEnvironmentKind.init(rawValue:)) ?? .release
        #if DEBUG || STAGING
        let sampleData = true
        #else
        let sampleData = false
        #endif

        return AppConfiguration(
            environment: environment,
            privacyPolicyURL: url("DLPrivacyPolicyURL", fallback: "https://example.com/delore/privacy"),
            supportURL: url("DLSupportURL", fallback: "https://example.com/delore/support"),
            termsURL: url("DLTermsURL", fallback: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"),
            products: ProductCatalog(
                oneTimeCleanup: string("DLProductOneTime") ?? "app.delore.cleanup.single",
                proMonthly: string("DLProductProMonthly") ?? "app.delore.pro.monthly",
                proYearly: string("DLProductProYearly") ?? "app.delore.pro.yearly"
            ),
            freeCleanupLimit: string("DLFreeCleanupLimit").flatMap(Int.init) ?? 50,
            analyticsEnabled: string("DLAnalyticsEnabled")?.uppercased() == "YES",
            features: FeatureFlags(sampleDataMode: sampleData, advancedFilters: true)
        )
    }
}
