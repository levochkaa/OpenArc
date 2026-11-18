// BrowserRealImportTests.swift

import Foundation
import Testing

// MARK: - BrowserRealImportTests

/// Reads the sidebar, bookmarks and history of every installed browser that
/// keeps Spaces in files of its own, from this Mac's real home, and prints what
/// came out. Run by hand with `TEST_RUNNER_OPENARC_REAL_IMPORT=1 ./build.sh test`;
/// `TEST_RUNNER_OPENARC_REAL_IMPORT_REPORT=<path>` also writes the summary there.
/// The test runner cannot read Vane's sandbox container; copy it into a home of
/// its own and pass `TEST_RUNNER_OPENARC_REAL_IMPORT_HOME=<path>`, which reads
/// that home and skips the end-to-end import, since the model reads the real one.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["OPENARC_REAL_IMPORT"] == "1"),
)
@MainActor struct BrowserRealImportTests {
    // MARK: Private

    private static let sources: [BrowserBookmarkImportSource] = [.cra, .crest, .yab, .vane, .search]

    private static func importer(
        _ source: BrowserBookmarkImportSource,
        profile: BrowserImportProfile,
        profiles: [BrowserImportProfile],
    ) -> BrowserProfileImporter {
        var importer = BrowserProfileImporter(source: source, profileDirectory: profile.directory)
        importer.profileName = profile.name
        importer.profiles = profiles
        importer.lastUsed = profile.lastUsed
        return importer
    }

    private static func describe(_ sidebar: BrowserImportedSidebar) -> [String] {
        var lines = sidebar.spaces.map { space in
            let theme = space.theme.map { " theme \($0.colors.count) colors" } ?? ""
            return "  Space \(space.title ?? "untitled") icon \(space.icon ?? "none")\(theme)"
                + " profile \(space.profileDirectory ?? "default"): "
                + space.pinned.map(describe).joined(separator: ", ")
        }
        lines.append("  favorites: " + sidebar.favorites.map(describe).joined(separator: ", "))
        if !sidebar.profileNames.isEmpty {
            lines.append("  profile names: " + sidebar.profileNames
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", "))
        }
        lines.append("  \(sidebar.spaces.count) Spaces, \(sidebar.pinnedTabCount) pinned tabs, "
            + "\(sidebar.favorites.count) favorites")
        return lines
    }

    private static func describe(_ node: BrowserImportedSidebar.Node) -> String {
        switch node {
        case .tab(let title, let savedTitle, let url):
            "\(title ?? savedTitle ?? "") <\(url)>"
        case .folder(let title, let icon, let children):
            "folder \(title ?? "untitled") (\(icon ?? "no icon")) ["
                + children.map(describe).joined(separator: ", ") + "]"
        }
    }

    private static func describe(_ items: [BrowserBookmarkImportItem]) -> [String] {
        items.map { item in
            item.urlString.map { "\(item.title) <\($0)>" }
                ?? "folder \(item.title) [" + describe(item.children).joined(separator: ", ") + "]"
        }
    }

    private static func urlCount(_ items: [BrowserBookmarkImportItem]) -> Int {
        items.reduce(0) { $0 + ($1.urlString == nil ? urlCount($1.children) : 1) }
    }

    // MARK: Internal

    @Test func readsEveryInstalledSidebarBrowser() async throws {
        var report = [String]()
        let home = ProcessInfo.processInfo.environment["OPENARC_REAL_IMPORT_HOME"]
        let locations = home.map { BrowserImportLocations(home: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? .current
        for source in Self.sources {
            let profiles = source.importProfiles(in: locations)
            guard let newest = profiles.first else {
                report.append("\(source.browserName): no profile on this Mac")
                continue
            }
            report.append("\(source.browserName): \(profiles.count) profile(s): "
                + profiles.map { "\($0.name) [\($0.directory.lastPathComponent)]" }.joined(separator: ", "))
            let sidebar: BrowserImportedSidebar
            do {
                sidebar = try BrowserImportedSidebar.load(source, locations: locations)
            } catch {
                let directory = source.webKitAppDirectory(in: locations) ?? newest.directory
                let listing = Result { try FileManager.default.contentsOfDirectory(atPath: directory.path) }
                report.append("  sidebar: \(error); listing \(directory.path): \(listing)")
                // macOS keeps Vane's container from the test runner; that is not the reader's fault.
                let kept = (try? listing.get()) == nil
                    && error as? BrowserImportedSidebar.ImportError == .unreadable
                if !kept {
                    Issue.record("\(source.browserName) sidebar: \(error)")
                }
                continue
            }
            #expect(!sidebar.spaces.isEmpty, "\(source.browserName) has a Space")
            report += Self.describe(sidebar)
            var bookmarkCount = 0
            var historyCount = 0
            for profile in profiles {
                let importer = Self.importer(source, profile: profile, profiles: profiles)
                let bookmarks = importer.bookmarkItems() ?? []
                let history = importer.history()
                bookmarkCount += Self.urlCount(bookmarks)
                historyCount += history.count
                report.append("  bookmarks of \(profile.name): "
                    + Self.describe(bookmarks).joined(separator: ", "))
                let dates = history.map(\.lastVisit).filter { $0 > 0 }
                if let oldest = dates.min(), let newestVisit = dates.max() {
                    report.append("  history of \(profile.name): \(history.count) pages, "
                        + "\(Date(timeIntervalSince1970: oldest)) to \(Date(timeIntervalSince1970: newestVisit))")
                    #expect(
                        newestVisit < Date().timeIntervalSince1970 + 86400,
                        "\(source.browserName) history dates are not in the future",
                    )
                    #expect(oldest > 1_000_000_000, "\(source.browserName) history dates are after 2001")
                } else {
                    report.append("  history of \(profile.name): \(history.count) pages")
                }
            }
            report.append("  total: \(bookmarkCount) bookmarks, \(historyCount) history pages")
            #expect(historyCount > 0, "\(source.browserName) has history")
            guard home == nil else { continue }

            let fixture = SidebarDragFixture(temporary: ["x"])
            let spacesBefore = fixture.model.spaces.count
            let tabsBefore = fixture.model.tabs.count
            let line = await fixture.model.importProfiles(
                profiles.map { Self.importer(source, profile: $0, profiles: profiles) },
                items: [.spaces, .bookmarks, .history],
            )
            report.append("  end to end: \(line) (\(fixture.model.spaces.count - spacesBefore) Spaces, "
                + "\(fixture.model.tabs.count - tabsBefore) tabs, "
                + "\(fixture.model.pinnedTabFolders.count) folders)")
            #expect(fixture.model.spaces.count - spacesBefore == sidebar.spaces.count)
        }
        let text = report.joined(separator: "\n")
        print(text)
        if let path = ProcessInfo.processInfo.environment["OPENARC_REAL_IMPORT_REPORT"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
