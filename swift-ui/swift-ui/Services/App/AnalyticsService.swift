import Foundation
import Aptabase

enum AnalyticsService {
    private static let firstLaunchKey = "hasLaunchedBefore"

    static func initialize() {
        Aptabase.shared.initialize(appKey: "A-US-0573120144") // TODO: 替换为你的 Aptabase App Key
    }

    static func track(_ event: String, with properties: [String: Any] = [:]) {
        if properties.isEmpty {
            Aptabase.shared.trackEvent(event)
        } else {
            Aptabase.shared.trackEvent(event, with: properties)
        }
    }

    static func trackFirstLaunchIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: firstLaunchKey) else { return }
        UserDefaults.standard.set(true, forKey: firstLaunchKey)
        track("first_launch")
    }

    static func trackError(_ context: String, error: Error) {
        guard !isNetworkError(error) else { return }
        track("app_error", with: [
            "context": context,
            "message": error.localizedDescription
        ])
    }

    private static func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }
        if nsError.domain == "NSPOSIXErrorDomain" {
            let networkCodes: Set<Int> = [
                48, /* EADDRINUSE */
                61, /* ECONNREFUSED */
                54, /* ECONNRESET */
                60, /* ETIMEDOUT */
                51, /* ENETUNREACH */
                50, /* ENETDOWN */
                65, /* EHOSTUNREACH */
            ]
            return networkCodes.contains(nsError.code)
        }
        return false
    }
}
