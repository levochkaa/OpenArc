// BrowserImportSource.swift

import Foundation

// MARK: - BrowserImportEngine

/// How a browser keeps its profile on disk, which decides how it is read.
enum BrowserImportEngine: String {
    case chromium
    case firefox
    case safari
    /// A WebKit browser with its own sidebar files. Its cookies and keychain
    /// items belong to it and cannot be read, so only its files come across.
    case webkitApp
}

// MARK: - BrowserImportLocations

/// Where other browsers keep their data. Tests point it at a home of their own.
struct BrowserImportLocations {
    static var current: BrowserImportLocations {
        let fileManager = FileManager.default
        return BrowserImportLocations(
            home: fileManager.homeDirectoryForCurrentUser,
            applicationSupport: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        )
    }

    let home: URL
    let applicationSupport: URL

    init(home: URL, applicationSupport: URL? = nil) {
        self.home = home
        self.applicationSupport = applicationSupport
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

// MARK: - BrowserImportProfile

/// One profile of another browser.
struct BrowserImportProfile: Hashable {
    let name: String
    let directory: URL
    /// The profile's latest activity, from its own records or its files' dates.
    let lastUsed: Date?
}

// MARK: - BrowserBookmarkImportSource

/// A browser OpenArc can import from.
enum BrowserBookmarkImportSource: String, CaseIterable, Identifiable {
    case arc
    case dia
    case chrome
    case brave
    case edge
    case opera
    case vivaldi
    case helium
    case comet
    case atlas
    case ardia
    case aside
    case cra
    case crest
    case chromium
    case firefox
    case zen
    case librewolf
    case floorp
    case waterfox
    case safari
    case yab
    case vane
    case search

    // MARK: Internal

    var id: String {
        rawValue
    }

    /// The product name, as the import lists show it.
    var browserName: String {
        switch self {
        case .arc: "Arc"
        case .dia: "Dia"
        case .chrome: "Google Chrome"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .opera: "Opera"
        case .vivaldi: "Vivaldi"
        case .helium: "Helium"
        case .comet: "Comet"
        case .atlas: "ChatGPT Atlas"
        case .ardia: "Ardia"
        case .aside: "Aside"
        case .cra: "Cra"
        case .crest: "Crest"
        case .chromium: "Chromium"
        case .firefox: "Firefox"
        case .zen: "Zen"
        case .librewolf: "LibreWolf"
        case .floorp: "Floorp"
        case .waterfox: "Waterfox"
        case .safari: "Safari"
        case .yab: "Yab"
        case .vane: "Vane"
        case .search: "Search"
        }
    }

    var title: String {
        BrowserStrings.bookmarksImport(from: browserName)
    }

    var importedFolderTitle: String {
        BrowserStrings.bookmarksImported(from: browserName)
    }

    var engine: BrowserImportEngine {
        switch self {
        case .arc, .ardia, .aside, .atlas, .brave, .chrome, .chromium, .comet, .cra, .crest, .dia, .edge, .helium,
             .opera, .vivaldi: .chromium
        case .firefox, .floorp, .librewolf, .waterfox, .zen: .firefox
        case .safari: .safari
        case .search, .vane, .yab: .webkitApp
        }
    }

    /// The app's bundle identifiers, the usual one first.
    var bundleIdentifiers: [String] {
        switch self {
        case .arc: ["company.thebrowser.Browser"]
        case .dia: ["company.thebrowser.dia"]
        case .chrome: ["com.google.Chrome"]
        case .brave: ["com.brave.Browser"]
        case .edge: ["com.microsoft.edgemac"]
        case .opera: ["com.operasoftware.Opera"]
        case .vivaldi: ["com.vivaldi.Vivaldi"]
        case .helium: ["net.imput.helium"]
        case .comet: ["ai.perplexity.comet"]
        case .atlas: ["com.openai.atlas"]
        case .ardia: ["com.ardia.browser"]
        case .aside: ["at.studio.AsideBrowser"]
        case .cra: ["dk.kildahl.cra"]
        case .crest: ["com.pauldavis.crest"]
        case .chromium: ["org.chromium.Chromium"]
        case .firefox: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        case .zen: ["app.zen-browser.zen"]
        case .librewolf: ["io.gitlab.librewolf-community.librewolf", "org.mozilla.librewolf"]
        case .floorp: ["one.ablaze.floorp"]
        case .waterfox: ["net.waterfox.waterfox", "org.waterfoxproject.waterfox"]
        case .safari: ["com.apple.Safari"]
        case .yab: ["dev.serafim.fast"]
        case .vane: ["io.github.notnaki.vane"]
        case .search: ["com.officecommun.search"]
        }
    }

    /// The keychain entry that seals a Chromium browser's passwords and cookies;
    /// nil where none is known.
    var keychainService: String? {
        switch self {
        case .arc: "Arc Safe Storage"
        case .dia: "Dia Safe Storage"
        case .chrome: "Chrome Safe Storage"
        case .brave: "Brave Safe Storage"
        case .edge: "Microsoft Edge Safe Storage"
        case .opera: "Opera Safe Storage"
        case .vivaldi: "Vivaldi Safe Storage"
        case .helium: "Helium Storage Key"
        case .comet: "Comet Safe Storage"
        case .ardia: "Ardia Safe Storage"
        case .aside: "Aside Safe Storage"
        case .cra: "Cra Safe Storage"
        case .crest: "Crest Safe Storage"
        case .chromium: "Chromium Safe Storage"
        case .atlas, .firefox, .floorp, .librewolf, .safari, .search, .vane, .waterfox, .yab, .zen: nil
        }
    }

    /// What can come across. Firefox seals passwords with NSS, which is not
    /// read here; Safari's come from its exported ZIP.
    var supportedImportItems: Set<BrowserOnboardingImportItem> {
        switch engine {
        case .chromium:
            var items: Set<BrowserOnboardingImportItem> = [.bookmarks, .history, .siteSearches, .extensions]
            if keychainService != nil {
                items.formUnion([.passwords, .signIns])
            }
            if keepsSidebarFiles {
                items.insert(.spaces)
            }
            return items
        case .firefox:
            return [.bookmarks, .history, .signIns]
        case .safari:
            return [.bookmarks, .history, .passwords]
        case .webkitApp:
            return [.spaces, .bookmarks, .history]
        }
    }

    /// Whether the browser keeps Spaces in files of its own that can be read.
    var keepsSidebarFiles: Bool {
        switch self {
        case .arc, .cra, .crest, .search, .vane, .yab: true
        default: false
        }
    }

    /// Safari's data is read from a ZIP the person exports from it.
    var importsFromExportArchive: Bool {
        engine == .safari
    }

    static func modificationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: WebKit apps

    /// Vane is sandboxed. Its container is only looked at from outside here:
    /// reading inside another app's container can bring up a privacy prompt,
    /// which only an import the person started may cause.
    static func vaneContainer(in locations: BrowserImportLocations) -> URL {
        locations.home.appendingPathComponent("Library/Containers/io.github.notnaki.vane", isDirectory: true)
    }

    // MARK: Private

    private static func holdsChromiumProfile(_ directory: URL, fileManager: FileManager) -> Bool {
        ["Preferences", "Bookmarks", "History"].contains {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private static func subdirectories(of directory: URL, fileManager: FileManager) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// The browser's folder in Application Support; nil for Safari.
    func dataDirectory(in locations: BrowserImportLocations) -> URL? {
        let path: String? =
            switch self {
            case .arc: "Arc/User Data"
            case .dia: "Dia/User Data"
            case .chrome: "Google/Chrome"
            case .brave: "BraveSoftware/Brave-Browser"
            case .edge: "Microsoft Edge"
            case .opera: "com.operasoftware.Opera"
            case .vivaldi: "Vivaldi"
            case .helium: "net.imput.helium"
            case .comet: "Comet"
            case .atlas: "com.openai.atlas/browser-data"
            case .ardia: "com.ardia.browser/Chromium"
            case .aside: "Aside"
            case .cra: "Cra/Chromium"
            case .crest: "Crest/Chromium"
            case .chromium: "Chromium"
            case .firefox: "Firefox"
            case .zen: "zen"
            case .librewolf: "librewolf"
            case .floorp: "Floorp"
            case .waterfox: "Waterfox"
            case .yab: "Yab"
            case .search: "Search"
            case .safari, .vane: nil
            }
        if self == .vane {
            return Self.vaneContainer(in: locations)
                .appendingPathComponent("Data/Library/Application Support/Vane", isDirectory: true)
        }
        return path.map { locations.applicationSupport.appendingPathComponent($0, isDirectory: true) }
    }

    /// Profiles that hold data, newest first.
    func importProfiles(
        in locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
    ) -> [BrowserImportProfile] {
        let profiles =
            switch engine {
            case .chromium: chromiumProfiles(in: locations, fileManager: fileManager)
            case .firefox: dataDirectory(in: locations).map {
                    BrowserFirefoxProfile.profiles(in: $0, fileManager: fileManager)
                } ?? []
            case .safari: [BrowserImportProfile]()
            case .webkitApp: webKitAppProfiles(in: locations, fileManager: fileManager)
            }
        return profiles.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    /// The folder a WebKit app keeps its files in: Yab's earlier versions used `Fast`.
    func webKitAppDirectory(
        in locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
    ) -> URL? {
        guard self == .yab else { return dataDirectory(in: locations) }
        let current = locations.applicationSupport.appendingPathComponent("Yab", isDirectory: true)
        let earlier = locations.applicationSupport.appendingPathComponent("Fast", isDirectory: true)
        let spaces = { (folder: URL) in
            fileManager.fileExists(atPath: folder.appendingPathComponent("spaces.json").path)
        }
        return spaces(current) || !spaces(earlier) ? current : earlier
    }

    // MARK: Chromium

    /// Folders holding `Local State`. Most browsers keep one at their data
    /// folder; Atlas keeps them up to two levels below it.
    func chromiumUserDataDirectories(
        in locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
    ) -> [URL] {
        guard engine == .chromium, let root = dataDirectory(in: locations) else { return [] }
        guard self == .atlas else { return [root] }
        var result = [URL]()
        var level = [root]
        for _ in 0..<3 {
            result += level.filter { fileManager.fileExists(atPath: $0.appendingPathComponent("Local State").path) }
            level = level.flatMap { Self.subdirectories(of: $0, fileManager: fileManager) }
        }
        return result
    }

    /// Every Chromium profile folder (`Default`, `Profile N`, Crest's `Crest-<id>`)
    /// with data. Opera keeps its only profile in the data folder itself.
    func chromiumProfileDirectories(
        in locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
    ) -> [URL] {
        chromiumUserDataDirectories(in: locations, fileManager: fileManager).flatMap { root -> [URL] in
            let named = Self.subdirectories(of: root, fileManager: fileManager)
                .filter { folder in
                    let name = folder.lastPathComponent
                    // Crest's `Default` serves only private windows; each of its Spaces has a profile.
                    return name == "Default" && self != .crest || name.hasPrefix("Profile ") || name.hasPrefix("Crest-")
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return ([root] + named).filter { Self.holdsChromiumProfile($0, fileManager: fileManager) }
        }
    }

    /// A file of each Chromium profile of the browser that has it; other engines have none.
    func chromiumProfileFiles(
        named fileName: String,
        in locations: BrowserImportLocations = .current,
        fileManager: FileManager = .default,
    ) -> [URL] {
        chromiumProfileDirectories(in: locations, fileManager: fileManager)
            .map { $0.appendingPathComponent(fileName, isDirectory: false) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// A WebKit app has one set of files, shown as one profile named for the app.
    private func webKitAppProfiles(
        in locations: BrowserImportLocations,
        fileManager: FileManager,
    ) -> [BrowserImportProfile] {
        guard let directory = webKitAppDirectory(in: locations, fileManager: fileManager) else { return [] }
        if self == .vane {
            guard fileManager.fileExists(atPath: Self.vaneContainer(in: locations).path) else { return [] }
            return [BrowserImportProfile(name: browserName, directory: directory, lastUsed: nil)]
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasSuffix(".json") }
        guard !files.isEmpty else { return [] }
        let lastUsed = files.compactMap {
            Self.modificationDate(of: directory.appendingPathComponent($0), fileManager: fileManager)
        }
        .max()
        return [BrowserImportProfile(name: browserName, directory: directory, lastUsed: lastUsed)]
    }

    /// Names and activity times from `Local State`, the profile picker's own list.
    private func chromiumProfiles(
        in locations: BrowserImportLocations,
        fileManager: FileManager,
    ) -> [BrowserImportProfile] {
        var infoByDirectory = [String: (name: String?, activeTime: Date?)]()
        for root in chromiumUserDataDirectories(in: locations, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cache = (state["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
            else { continue }
            for (directory, value) in cache {
                guard let info = value as? [String: Any] else { continue }
                let path = root.appendingPathComponent(directory, isDirectory: true).standardizedFileURL.path
                infoByDirectory[path] = (
                    info["name"] as? String,
                    (info["active_time"] as? Double).map(Date.init(timeIntervalSince1970:)),
                )
            }
        }
        let roots = Set(chromiumUserDataDirectories(in: locations, fileManager: fileManager)
            .map(\.standardizedFileURL.path))
        // Cra names its profiles, and Crest's are named for their Spaces, in their own files.
        let sidebarNames = self == .cra || self == .crest
            ? (try? BrowserImportedSidebar.load(self, locations: locations, fileManager: fileManager))?
                .profileNames ?? [:]
            : [:]
        return chromiumProfileDirectories(in: locations, fileManager: fileManager).map { directory in
            let path = directory.standardizedFileURL.path
            let info = infoByDirectory[path]
            let activity = ["History", "Bookmarks"].compactMap {
                Self.modificationDate(of: directory.appendingPathComponent($0), fileManager: fileManager)
            } + [info?.activeTime].compactMap(\.self)
            let lastUsed = activity.max()
                ?? Self.modificationDate(of: directory.appendingPathComponent("Preferences"), fileManager: fileManager)
            let fallbackName = roots.contains(path) ? browserName : directory.lastPathComponent
            // Chromium's placeholder for an unnamed first profile reads as its folder.
            let name = sidebarNames[directory.lastPathComponent]
                ?? info?.name.flatMap { $0.isEmpty || BrowserProfile.placeholderNames.contains($0) ? nil : $0 }
                ?? fallbackName
            return BrowserImportProfile(name: name, directory: directory, lastUsed: lastUsed)
        }
    }
}
