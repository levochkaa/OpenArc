// BrowserFolderPreviewTests.swift

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
            ],
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
                faviconURL: nil,
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
            doCommandBy: #selector(NSResponder.insertNewline(_:)),
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
            defer: false,
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
            faviconURL: nil,
            subtitle: "1 hour ago",
        )] }
        coordinator.name = { _ in "Work" }
        coordinator.show(folderID: "f", beside: row)
        let panel = try #require(coordinator.panel)
        #expect(panel.parent === window)
        let editor = panel.firstResponder as? NSTextView
        #expect(
            panel.firstResponder === panel.searchField || editor?.delegate === panel.searchField,
            "Typing goes to the search at once",
        )
        #expect(panel.searchField.placeholderString == String(
            format: BrowserStrings.folderPreviewSearchNamedPlaceholder,
            "Work",
        ))
        #expect(
            panel.preferredSize.height == BrowserFolderPreviewPanel.size(
                forRowCount: 1,
                rowHeight: BrowserFolderPreviewPanel.twoLineRowHeight,
            )
            .height,
            "A second line makes the rows taller",
        )
        #expect(!panel.hasQuery)
        #expect(coordinator.shownFolderID == "f")
        coordinator.isEnabled = { false }
        coordinator.dismiss()
        coordinator.show(folderID: "f", beside: row)
        #expect(coordinator.panel == nil, "Turned off in Settings")
    }

    @Test func passingOverAnotherFolderStillHidesThePreview() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 1000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let rowA = NSView(frame: NSRect(x: 10, y: 500, width: 200, height: 30))
        let rowB = NSView(frame: NSRect(x: 10, y: 460, width: 200, height: 30))
        window.contentView?.addSubview(rowA)
        window.contentView?.addSubview(rowB)
        let coordinator = BrowserFolderPreviewCoordinator()
        coordinator.items = { id in
            [BrowserFolderPreviewItem(id: id, title: id, urlString: "https://\(id).example", faviconURL: nil)]
        }
        defer { coordinator.dismiss() }

        coordinator.show(folderID: "a", beside: rowA)
        coordinator.rowHoverChanged(folderID: "a", row: rowA, hovered: false)
        coordinator.rowHoverChanged(folderID: "b", row: rowB, hovered: true)
        coordinator.rowHoverChanged(folderID: "b", row: rowB, hovered: false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(coordinator.panel == nil, "Sweeping across folder B still hides A's preview")

        coordinator.show(folderID: "a", beside: rowA)
        coordinator.rowHoverChanged(folderID: "a", row: rowA, hovered: false)
        coordinator.rowHoverChanged(folderID: "b", row: rowB, hovered: true)
        try await Task.sleep(for: .milliseconds(800))
        #expect(coordinator.shownFolderID == "b", "Resting on B replaces A's preview after it hides")
    }
}

// MARK: - BrowserFolderCopyAllLinksTests

@Suite(.serialized)
@MainActor struct BrowserFolderCopyAllLinksTests {
    @Test func copyAllLinksPutsEveryTabOfTheFolderOnItsOwnLine() {
        let f = SidebarDragFixture(
            pinned: [("one", "folder"), ("two", "folder"), ("out", nil)],
            folders: [.init(id: "folder", spaceID: "s", title: "Folder")],
        )
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types {
                    item.setData(data, forType: type)
                }
                return item
            })
        }
        #expect(f.model.copyAllLinks(inFolderID: "folder"))
        #expect(pasteboard.string(forType: .string) == "https://one.example\nhttps://two.example")
        #expect(!f.model.copyAllLinks(inFolderID: "missing"))
    }
}
