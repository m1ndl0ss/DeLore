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
    let advancedFilters: Bool
    /// Publisher worker base endpoint (`…/v1/notify`). Empty disables notify + free-usage sync.
    /// Auth is a short-lived token from `/v1/token` — no shared secret in the app.
    let notifyURL: String
    /// Hosted percent-off code list. Not linked from the public site.
    let promoCatalogURL: URL

    /// Pacing for destructive requests. Tune here; the engine reads every limit from it.
    let ratePolicy: RatePolicy = .conservative

    static func load(from bundle: Bundle = .main) -> AppConfiguration {
        func string(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        }
        func url(_ key: String, fallback: String) -> URL {
            string(key).flatMap(URL.init(string:)) ?? URL(string: fallback)!
        }

        let environment = string("DLEnvironment").flatMap(AppEnvironmentKind.init(rawValue:)) ?? .release

        return AppConfiguration(
            environment: environment,
            privacyPolicyURL: url("DLPrivacyPolicyURL", fallback: "https://kandalintsev.com/retract/privacy"),
            supportURL: url("DLSupportURL", fallback: "mailto:contact@kandalintsev.com"),
            termsURL: url("DLTermsURL", fallback: "https://kandalintsev.com/retract/terms"),
            products: ProductCatalog(
                oneTimeCleanup: string("DLProductOneTime") ?? "app.retract.cleanup.single",
                proMonthly: string("DLProductProMonthly") ?? "app.retract.pro.monthly",
                proYearly: string("DLProductProYearly") ?? "app.retract.pro.yearly",
                proMonthlyPromo: string("DLProductProMonthlyPromo") ?? "app.retract.pro.monthly.promo",
                proYearlyPromo: string("DLProductProYearlyPromo") ?? "app.retract.pro.yearly.promo"
            ),
            freeCleanupLimit: string("DLFreeCleanupLimit").flatMap(Int.init) ?? 100,
            analyticsEnabled: string("DLAnalyticsEnabled")?.uppercased() == "YES",
            advancedFilters: true,
            notifyURL: string("DLNotifyURL") ?? "",
            promoCatalogURL: url("DLPromoCatalogURL", fallback: RemotePromoCatalog.defaultURL.absoluteString)
        )
    }
}
