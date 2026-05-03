import CoreGraphics
import Foundation
import OSLog

// MARK: - BrowserTemporaryTabLifetime

enum BrowserTemporaryTabLifetime: String, CaseIterable, Codable, Equatable, Hashable {
    case twelveHours = "12h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    // MARK: Internal

    static let defaultValue = BrowserTemporaryTabLifetime.thirtyDays

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

// MARK: - BrowserTabPlacement

enum BrowserTabPlacement: String, Codable, Equatable, Hashable {
    case temporary
    case spacePinned
    case app
}

// MARK: - BrowserSpaceSessionSnapshot

struct BrowserSpaceSessionSnapshot: Codable, Equatable {
    // MARK: Lifecycle

    init(
        id: String,
        title: String,
        systemImageName: String,
        isPinnedSectionCollapsed: Bool = false,
        selectedTabIndex: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImageName = systemImageName
        self.isPinnedSectionCollapsed = isPinnedSectionCollapsed
        self.selectedTabIndex = selectedTabIndex
    }

    // MARK: Internal

    let id: String
    let title: String
    let systemImageName: String
    let isPinnedSectionCollapsed: Bool
    let selectedTabIndex: Int?
}

// MARK: - BrowserTabSessionSnapshotTab

struct BrowserTabSessionSnapshotTab: Codable, Equatable {
    // MARK: Lifecycle

    init(
        urlString: String,
        userTitleOverride: String? = nil,
        placement: BrowserTabPlacement = .temporary,
        spaceID: String? = nil,
        lastActivityTimestamp: TimeInterval? = nil
    ) {
        self.urlString = urlString
        self.userTitleOverride = userTitleOverride
        self.placement = placement
        self.spaceID = spaceID
        self.lastActivityTimestamp = lastActivityTimestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.urlString = try container.decode(String.self, forKey: .urlString)
        self.userTitleOverride = try container.decodeIfPresent(String.self, forKey: .userTitleOverride)
        if let placement = try container.decodeIfPresent(BrowserTabPlacement.self, forKey: .placement) {
            self.placement = placement
        } else {
            let legacyPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            self.placement = legacyPinned ? .spacePinned : .temporary
        }
        self.spaceID = try container.decodeIfPresent(String.self, forKey: .spaceID)
        self.lastActivityTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .lastActivityTimestamp)
    }

    // MARK: Internal

    let urlString: String
    let userTitleOverride: String?
    let placement: BrowserTabPlacement
    let spaceID: String?
    let lastActivityTimestamp: TimeInterval?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(urlString, forKey: .urlString)
        try container.encodeIfPresent(userTitleOverride, forKey: .userTitleOverride)
        try container.encode(placement, forKey: .placement)
        try container.encodeIfPresent(spaceID, forKey: .spaceID)
        try container.encodeIfPresent(lastActivityTimestamp, forKey: .lastActivityTimestamp)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case urlString
        case userTitleOverride
        case placement
        case spaceID
        case isPinned
        case lastActivityTimestamp
    }
}

// MARK: - BrowserTabSessionSnapshot

struct BrowserTabSessionSnapshot: Codable, Equatable {
    // MARK: Lifecycle

    init(
        version: Int = currentVersion,
        spaces: [BrowserSpaceSessionSnapshot]? = nil,
        tabs: [BrowserTabSessionSnapshotTab]
    ) {
        self.version = version
        self.spaces = spaces
        self.tabs = tabs
    }

    init(version: Int = currentVersion, tabURLStrings: [String]) {
        self.init(
            version: version,
            tabs: tabURLStrings.map { BrowserTabSessionSnapshotTab(urlString: $0) }
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.spaces = try container.decodeIfPresent([BrowserSpaceSessionSnapshot].self, forKey: .spaces)

        if let tabs = try container.decodeIfPresent([BrowserTabSessionSnapshotTab].self, forKey: .tabs) {
            self.tabs = tabs
            return
        }

        let tabURLStrings = try container.decode([String].self, forKey: .tabURLStrings)
        self.tabs = tabURLStrings.map { BrowserTabSessionSnapshotTab(urlString: $0) }
    }

    // MARK: Internal

    static let currentVersion = 3

    let version: Int
    let spaces: [BrowserSpaceSessionSnapshot]?
    let tabs: [BrowserTabSessionSnapshotTab]

    var tabURLStrings: [String] {
        tabs.map(\.urlString)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(spaces, forKey: .spaces)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(tabURLStrings, forKey: .tabURLStrings)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case version
        case spaces
        case tabs
        case tabURLStrings
    }
}

// MARK: - BrowserTabSessionSnapshotStoring

protocol BrowserTabSessionSnapshotStoring {
    func loadSnapshot() -> BrowserTabSessionSnapshot?
    func saveSnapshot(_ snapshot: BrowserTabSessionSnapshot)
}

// MARK: - BrowserSessionPreferencesStoring

protocol BrowserSessionPreferencesStoring {
    func loadSelectedTabIndex(tabCount: Int) -> Int?
    func saveSelectedTabIndex(_ index: Int?)
    func loadSelectedSpaceIndex(spaceCount: Int) -> Int?
    func saveSelectedSpaceIndex(_ index: Int?)
    func loadSidebarWidth(minimum: CGFloat, maximum: CGFloat) -> CGFloat?
    func saveSidebarWidth(_ width: CGFloat)
    func loadTemporaryTabLifetime() -> BrowserTemporaryTabLifetime
    func saveTemporaryTabLifetime(_ lifetime: BrowserTemporaryTabLifetime)
}

// MARK: - BrowserSessionDiagnostics

private enum BrowserSessionDiagnostics {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.levochkaa.TheBrowser",
        category: "Session"
    )
}

// MARK: - BrowserTabSessionSnapshotStore

final class BrowserTabSessionSnapshotStore: BrowserTabSessionSnapshotStoring {
    // MARK: Lifecycle

    init(snapshotURL: URL?, fileManager: FileManager = .default) {
        self.snapshotURL = snapshotURL
        self.fileManager = fileManager
    }

    // MARK: Internal

    static let snapshotFileName = "tabs.json"

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
            guard (1...BrowserTabSessionSnapshot.currentVersion).contains(snapshot.version) else {
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

    // MARK: Private

    private let snapshotURL: URL?
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
}

// MARK: - BrowserSessionPreferencesStore

final class BrowserSessionPreferencesStore: BrowserSessionPreferencesStoring {
    // MARK: Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: Internal

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

    func loadSelectedSpaceIndex(spaceCount: Int) -> Int? {
        guard spaceCount > 0 else {
            return nil
        }

        guard userDefaults.object(forKey: Key.selectedSpaceIndex) != nil else {
            return nil
        }

        let storedIndex = userDefaults.integer(forKey: Key.selectedSpaceIndex)
        return min(max(storedIndex, 0), spaceCount - 1)
    }

    func saveSelectedSpaceIndex(_ index: Int?) {
        guard let index else {
            userDefaults.removeObject(forKey: Key.selectedSpaceIndex)
            return
        }

        userDefaults.set(index, forKey: Key.selectedSpaceIndex)
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

    // MARK: Private

    private enum Key {
        static let selectedTabIndex = "browser.session.selectedTabIndex"
        static let selectedSpaceIndex = "browser.session.selectedSpaceIndex"
        static let sidebarWidth = "browser.session.sidebarWidth"
        static let temporaryTabLifetime = "browser.settings.temporaryTabLifetime"
    }

    private let userDefaults: UserDefaults
}
