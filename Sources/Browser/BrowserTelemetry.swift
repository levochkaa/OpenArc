import Foundation
import Sentry

// MARK: - BrowserTelemetryEvent

enum BrowserTelemetryEvent: String {
    case appLaunch = "app_launch"
    case appBecameActive = "app_became_active"
    case profileWindowOpened = "profile_window_opened"
    case tabCreated = "tab_created"
    case tabSelected = "tab_selected"
    case tabClosed = "tab_closed"
    case tabNavigated = "tab_navigated"
    case tabReloaded = "tab_reloaded"
    case bookmarkOpened = "bookmark_opened"
    case spaceCreated = "space_created"
    case spaceSelected = "space_selected"
    case commandBarPresented = "command_bar_presented"
    case currentPageCommandBarPresented = "current_page_command_bar_presented"
    case findPresented = "find_presented"
    case syncPushFailed = "sync_push_failed"
    case syncPullFailed = "sync_pull_failed"
    case profileBackupCreated = "profile_backup_created"
    case profileBackupFailed = "profile_backup_failed"
}

// MARK: - BrowserTelemetry

@MainActor enum BrowserTelemetry {
    // MARK: Internal

    static func startIfConfigured() {
        guard !hasStarted, let dsn = infoString("TheBrowserSentryDSN"), isUsableConfigurationValue(dsn) else {
            return
        }

        let tracesSampleRate = sampleRate(for: "TheBrowserSentryTracesSampleRate", defaultValue: 0.2)
        let profilesSampleRate = sampleRate(for: "TheBrowserSentryProfilesSampleRate", defaultValue: 0)

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = infoString("TheBrowserSentryEnvironment") ?? "development"
            options.tracesSampleRate = NSNumber(value: tracesSampleRate)
            options.enableAutoPerformanceTracing = tracesSampleRate > 0
            if profilesSampleRate > 0 {
                options.configureProfiling = { profiling in
                    profiling.lifecycle = .trace
                    profiling.sessionSampleRate = Float(profilesSampleRate)
                    profiling.profileAppStarts = true
                }
            }
            if let releaseName {
                options.releaseName = releaseName
            }
        }

        hasStarted = true
        usageAnalyticsEnabled = boolInfoValue("TheBrowserSentryUsageAnalyticsEnabled", defaultValue: true)
        captureUsage(.appLaunch, properties: baseProperties)
    }

    static func captureUsage(
        _ event: BrowserTelemetryEvent,
        properties: [String: String] = [:]
    ) {
        guard hasStarted, usageAnalyticsEnabled else {
            return
        }

        let message = ([event.rawValue] + normalizedProperties(properties)).joined(separator: " ")
        SentrySDK.capture(message: "browser.usage.\(message)")
    }

    static func captureError(
        _ error: Error,
        event: BrowserTelemetryEvent,
        properties: [String: String] = [:]
    ) {
        guard hasStarted else {
            return
        }

        captureUsage(event, properties: properties)
        SentrySDK.capture(error: error)
    }

    // MARK: Private

    private static var hasStarted = false
    private static var usageAnalyticsEnabled = false

    private static var baseProperties: [String: String] {
        [
            "bundle": Bundle.main.bundleIdentifier ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        ]
    }

    private static var releaseName: String? {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return nil
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(bundleID)@\(version)+\(build)"
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func sampleRate(for key: String, defaultValue: Double) -> Double {
        guard
            let rawValue = infoString(key),
            let value = Double(rawValue)
        else {
            return defaultValue
        }

        return min(max(value, 0), 1)
    }

    private static func boolInfoValue(_ key: String, defaultValue: Bool) -> Bool {
        guard let value = infoString(key)?.lowercased() else {
            return defaultValue
        }

        switch value {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return defaultValue
        }
    }

    private static func isUsableConfigurationValue(_ value: String) -> Bool {
        !value.contains("$(")
    }

    private static func normalizedProperties(_ properties: [String: String]) -> [String] {
        properties
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { key, value in
                "\(sanitize(key))=\(sanitize(value))"
            }
            .sorted()
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:/"))
        return String(value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
    }
}
