import CoreGraphics
import Foundation
import OSLog

enum BrowserTemporaryTabLifetime: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case twelveHours = "12h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    static let defaultValue: BrowserTemporaryTabLifetime = .thirtyDays

    var timeInterval: TimeInterval {
        switch self {
        case .twelveHours:
            12 * 60 * 60
        case .twentyFourHours:
            24 * 60 * 60
        case .sevenDays:
            7 * 24 * 60 * 60
        case .thirtyDays:
            30 * 24 * 60 * 60
        }
    }
}

struct BrowserTabSessionSnapshotTab: Codable, Equatable {
    let urlString: String
    let userTitleOverride: String?
    let isPinned: Bool
    let lastActivityTimestamp: TimeInterval?

    init(
        urlString: String,
        userTitleOverride: String? = nil,
        isPinned: Bool = false,
        lastActivityTimestamp: TimeInterval? = nil
    ) {
        self.urlString = urlString
        self.userTitleOverride = userTitleOverride
        self.isPinned = isPinned
        self.lastActivityTimestamp = lastActivityTimestamp
    }

    private enum CodingKeys: String, CodingKey {
        case urlString
        case userTitleOverride
        case isPinned
        case lastActivityTimestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        urlString = try container.decode(String.self, forKey: .urlString)
        userTitleOverride = try container.decodeIfPresent(String.self, forKey: .userTitleOverride)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        lastActivityTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .lastActivityTimestamp)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urlString, forKey: .urlString)
        try container.encodeIfPresent(userTitleOverride, forKey: .userTitleOverride)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(lastActivityTimestamp, forKey: .lastActivityTimestamp)
    }
}

struct BrowserTabSessionSnapshot: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let tabs: [BrowserTabSessionSnapshotTab]

    var tabURLStrings: [String] {
        tabs.map(\.urlString)
    }

    init(version: Int = currentVersion, tabs: [BrowserTabSessionSnapshotTab]) {
        self.version = version
        self.tabs = tabs
    }

    init(version: Int = currentVersion, tabURLStrings: [String]) {
        self.init(
            version: version,
            tabs: tabURLStrings.map { BrowserTabSessionSnapshotTab(urlString: $0) }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tabs
        case tabURLStrings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)

        if let tabs = try container.decodeIfPresent([BrowserTabSessionSnapshotTab].self, forKey: .tabs) {
            self.tabs = tabs
            return
        }

        let tabURLStrings = try container.decode([String].self, forKey: .tabURLStrings)
        tabs = tabURLStrings.map { BrowserTabSessionSnapshotTab(urlString: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(tabURLStrings, forKey: .tabURLStrings)
    }
}

protocol BrowserTabSessionSnapshotStoring {
    func loadSnapshot() -> BrowserTabSessionSnapshot?
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot)
}

protocol BrowserSessionPreferencesStoring {
    func loadSelectedTabIndex(tabCount: Int) -> Int?
    func saveSelectedTabIndex(_ index: Int?)
    func loadSidebarWidth(minimum: CGFloat, maximum: CGFloat) -> CGFloat?
    func saveSidebarWidth(_ width: CGFloat)
    func loadTemporaryTabLifetime() -> BrowserTemporaryTabLifetime
    func saveTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime)
}

private enum BrowserSessionDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        category: "Session"
    )
}

final class BrowserTabSessionSnapshotStore: BrowserTabSessionSnapshotStoring {
    static let snapshotFileName = "tabs.json"

    private let snapshotURL: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(snapshotURL: URL?, fileManager: FileManager = .default) {
        self.snapshotURL = snapshotURL
        self.fileManager = fileManager
    }

    func loadSnapshot() -> BrowserTabSessionSnapshot? {
        guard let snapshotURL else {
            return nil
        }

        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            let snapshot = try decoder.decode(BrowserTabSessionSnapshot.self, from: data)
            guard (1 ... BrowserTabSessionSnapshot.currentVersion).contains(snapshot.version) else {
                BrowserSessionDiagnostics.logger.warning(
                    "Ignoring session snapshot with unsupported version \(snapshot.version, privacy: .public)"
                )
                return nil
            }
            return snapshot
        } catch {
            BrowserSessionDiagnostics.logger.error(
                "Failed to load session snapshot: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot) {
        guard let snapshotURL else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            BrowserSessionDiagnostics.logger.error(
                "Failed to save session snapshot: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

final class BrowserSessionPreferencesStore: BrowserSessionPreferencesStoring {
    private enum Key {
        static let selectedTabIndex = "browser.session.selectedTabIndex"
        static let sidebarWidth = "browser.session.sidebarWidth"
        static let temporaryTabLifetime = "browser.settings.temporaryTabLifetime"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadSelectedTabIndex(tabCount: Int) -> Int? {
        guard tabCount > 0 else {
            return nil
        }

        guard userDefaults.object(forKey: Key.selectedTabIndex) != nil else {
            return nil
        }

        let storedIndex = userDefaults.integer(forKey: Key.selectedTabIndex)
        return min(max(storedIndex, 0), tabCount - 1)
    }

    func saveSelectedTabIndex(_ index: Int?) {
        guard let index else {
            userDefaults.removeObject(forKey: Key.selectedTabIndex)
            return
        }

        userDefaults.set(index, forKey: Key.selectedTabIndex)
    }

    func loadSidebarWidth(minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard userDefaults.object(forKey: Key.sidebarWidth) != nil else {
            return nil
        }

        let storedWidth = CGFloat(userDefaults.double(forKey: Key.sidebarWidth))
        guard storedWidth.isFinite else {
            return nil
        }

        return min(max(storedWidth, minimum), maximum)
    }

    func saveSidebarWidth(_ width: CGFloat) {
        guard width.isFinite else {
            return
        }

        userDefaults.set(Double(width), forKey: Key.sidebarWidth)
    }

    func loadTemporaryTabLifetime() -> BrowserTemporaryTabLifetime {
        guard
            let storedValue = userDefaults.string(forKey: Key.temporaryTabLifetime),
            let lifetime = BrowserTemporaryTabLifetime(rawValue: storedValue)
        else {
            return .defaultValue
        }

        return lifetime
    }

    func saveTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime) {
        userDefaults.set(lifetime.rawValue, forKey: Key.temporaryTabLifetime)
    }
}
