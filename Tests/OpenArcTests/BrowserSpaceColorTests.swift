import AppKit
import Testing

// MARK: - BrowserSpaceColorTests

@Suite(.serialized)
@MainActor struct BrowserSpaceColorTests {
    @Test func spaceColorsSurviveTheStoreButNotEquality() throws {
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("SpaceColors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("session.sqlite")
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [
                .init(id: "s", title: "Work", systemImageName: "star", colorName: "teal"),
                .init(id: "t", title: "Home", systemImageName: "house"),
            ],
            tabs: [.init(id: "a", urlString: "https://a.example", spaceID: "s")]
        )
        do {
            let store = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
            store.saveSnapshot(snapshot)
        }
        let reopened = try BrowserSQLiteSessionStore(databaseURL: databaseURL)
        #expect(try #require(reopened.loadSnapshot()?.spaces).map(\.colorName) == ["teal", nil])
        #expect(
            BrowserSpaceSessionSnapshot(id: "s", title: "Work", systemImageName: "star", colorName: "teal")
                == BrowserSpaceSessionSnapshot(id: "s", title: "Work", systemImageName: "star"),
            "Colors are local, so sync checks ignore them"
        )
    }

    @Test func aSpacesColorTintsTheWindowWhileItIsSelected() throws {
        let f = SidebarDragFixture(temporary: ["x"])
        #expect(f.model.selectedSpaceColor == nil, "Spaces start neutral")
        #expect(f.model.setColor(.teal, forSpaceID: "s"))
        #expect(!f.model.setColor(.teal, forSpaceID: "s"))
        #expect(!f.model.setColor(.red, forSpaceID: "missing"))
        #expect(f.model.selectedSpaceColor == .teal)
        let saved = try #require(f.store.savedSnapshots.last?.spaces)
        #expect(saved.first { $0.id == "s" }?.colorName == "teal")
        f.model.selectSpace(id: "t")
        #expect(f.model.selectedSpaceColor == nil)
        f.model.selectSpace(id: "s")
        #expect(f.model.setColor(nil, forSpaceID: "s") && f.model.selectedSpaceColor == nil)
    }

    @Test func theSpaceMenuOffersColorsWithTheCurrentOneChecked() throws {
        let space = BrowserChromeModel.Space(
            id: "s", title: "Work", systemImageName: "star", isPinnedSectionCollapsed: false, selectedTabID: nil
        )
        var chosen = [BrowserSpaceColor?]()
        let menu = BrowserNativeMenus.space(
            space,
            canDelete: true,
            color: .green,
            onRename: {},
            onChangeIcon: { _ in },
            onChangeColor: { chosen.append($0) },
            onDelete: {}
        )
        let colors = try #require(menu.items.first { $0.title == BrowserStrings.spaceChangeColorAction }?.submenu)
        #expect(colors.items.first?.title == BrowserStrings.spaceColorNone)
        let green = try #require(colors.items.first { $0.title == BrowserSpaceColor.green.title })
        #expect(green.state == .on)
        colors.performActionForItem(at: 0)
        #expect(chosen == [nil])
    }

    @Test func aColorOnlyChangeIsNotDroppedAsADuplicateWrite() {
        func write(_ color: String?) -> BrowserSessionWrite {
            BrowserSessionWrite(
                snapshot: .init(
                    spaces: [.init(id: "s", title: "Work", systemImageName: "star", colorName: color)],
                    tabs: []
                ),
                origin: .local(syncMove: nil)
            )
        }
        var buffer = BrowserSessionWriteBuffer()
        let accepted = [buffer.append(write(nil)), buffer.append(write("teal"))]
        #expect(accepted == [true, true] && buffer.writes.count == 2)
    }
}
