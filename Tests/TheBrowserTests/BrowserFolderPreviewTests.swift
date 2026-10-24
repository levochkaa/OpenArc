import AppKit
import Testing

// MARK: - BrowserFolderPreviewTests

@Suite(.serialized)
@MainActor struct BrowserFolderPreviewTests {
    @Test func aFolderPreviewListsItsTabsAndSubfoldersInSidebarOrder() {
        let f = SidebarDragFixture(
            pinned: [("a", "outer"), ("b", "inner"), ("c", nil)],
            temporary: ["x"],
            folders: [
                .init(id: "outer", spaceID: "s", title: "Outer", isExpanded: false),
                .init(id: "inner", spaceID: "s", parentFolderID: "outer", title: "Inner", isExpanded: false),
            ]
        )
        let state = BrowserNativeSidebarState(model: f.model, snapshot: f.model.sidebarSnapshot, sidebarWidth: 240)
        let items = state.folderPreviewItems(folderID: "outer")
        #expect(items.map(\.title) == ["a", "b"])
        #expect(state.folderPreviewItems(folderID: "missing").isEmpty)
    }

    @Test func thePreviewFiltersAndSelectsFromTheKeyboard() {
        let items = ["Mail", "Calendar", "Docs"].map {
            BrowserFolderPreviewItem(
                id: $0,
                title: $0,
                urlString: "https://\($0.lowercased()).example",
                faviconURL: nil
            )
        }
        let panel = BrowserFolderPreviewPanel(items: items)
        defer { panel.orderOut(nil) }
        #expect(panel.preferredSize.height == BrowserFolderPreviewPanel.size(forRowCount: 3).height)
        var selected = [String]()
        panel.onSelect = { selected.append($0) }
        panel.searchField.stringValue = "cal"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchField))
        #expect(panel.visibleItems.map(\.id) == ["Calendar"])
        let editor = NSTextView()
        #expect(panel.control(
            panel.searchField,
            textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(selected == ["Calendar"])

        panel.searchField.stringValue = ""
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchField))
        _ = panel.control(panel.searchField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        #expect(panel.selectedIndex == 1)
        var cancelled = false
        panel.onCancel = { cancelled = true }
        _ = panel.control(panel.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(cancelled)
    }

    @Test func thePreviewOpensBesideTheRowOnThePageSide() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let row = NSView(frame: NSRect(x: 10, y: 500, width: 200, height: 30))
        window.contentView?.addSubview(row)
        let size = NSSize(width: 280, height: 120)
        let frame = BrowserFolderPreviewCoordinator.frame(for: size, beside: row)
        let rowFrame = window.convertToScreen(row.convert(row.bounds, to: nil))
        #expect(frame.minX >= rowFrame.maxX, "A left sidebar opens the preview to the right")
        #expect(frame.size == size)

        let coordinator = BrowserFolderPreviewCoordinator()
        coordinator.items = { _ in [BrowserFolderPreviewItem(
            id: "t",
            title: "T",
            urlString: "https://t.example",
            faviconURL: nil
        )] }
        coordinator.show(folderID: "f", beside: row)
        let panel = try #require(coordinator.panel)
        #expect(panel.parent === window && !panel.isKeyWindow, "Showing does not take the keyboard")
        #expect(coordinator.shownFolderID == "f")
        coordinator.isEnabled = { false }
        coordinator.dismiss()
        coordinator.show(folderID: "f", beside: row)
        #expect(coordinator.panel == nil, "Turned off in Settings")
    }
}
