// BrowserSidebarSnapshotTests.swift

import Foundation
import Testing

@Test func collapsedPinnedFolderShowsMultipleRevealedChildrenWhenSelectedInsideFolder() {
    let space = BrowserChromeModel.Space(
        id: "space",
        title: "Space",
        systemImageName: "square.grid.2x2",
        isPinnedSectionCollapsed: false,
        selectedTabID: "folder-tab-2",
    )
    let folder = BrowserChromeModel.PinnedTabFolder(
        id: "folder",
        spaceID: space.id,
        parentFolderID: nil,
        title: "Folder",
        systemImageName: nil,
        isExpanded: false,
    )
    let firstFolderTab = browserSidebarSnapshotTestTab(
        id: "folder-tab-1",
        spaceID: space.id,
        title: "First Folder Tab",
        urlString: "https://first.example",
        placement: .spacePinned,
        pinnedFolderID: folder.id,
    )
    let secondFolderTab = browserSidebarSnapshotTestTab(
        id: "folder-tab-2",
        spaceID: space.id,
        title: "Second Folder Tab",
        urlString: "https://second.example",
        placement: .spacePinned,
        pinnedFolderID: folder.id,
    )
    let snapshot = BrowserSidebarSnapshot(
        spaces: [space],
        selectedSpaceID: space.id,
        activeSpace: space,
        isActiveSpacePinnedSectionCollapsed: false,
        allTabs: [firstFolderTab, secondFolderTab],
        pinnedTabFolders: [folder],
        appTabs: [],
        spacePinnedTabs: [firstFolderTab, secondFolderTab],
        temporaryTabs: [],
        selectedTabID: secondFolderTab.id,
        archivableTabIDs: [],
        canGoBack: false,
        canGoForward: false,
        canStopLoading: false,
        canReload: false,
    )

    let rows = snapshot.visiblePinnedRows(
        in: space.id,
        revealedTabIDsByFolderID: [folder.id: [firstFolderTab.id, secondFolderTab.id]],
    )

    #expect(rows.map(\.id) == [
        "folder-\(folder.id)",
        "tab-\(firstFolderTab.id)",
        "tab-\(secondFolderTab.id)",
    ])
}

@Test func collapsedPinnedFolderKeepsRevealedChildrenWhenSelectedTabIsOutsideFolder() {
    let space = BrowserChromeModel.Space(
        id: "space",
        title: "Space",
        systemImageName: "square.grid.2x2",
        isPinnedSectionCollapsed: false,
        selectedTabID: "active-tab",
    )
    let folder = BrowserChromeModel.PinnedTabFolder(
        id: "folder",
        spaceID: space.id,
        parentFolderID: nil,
        title: "Folder",
        systemImageName: nil,
        isExpanded: false,
    )
    let folderTab = browserSidebarSnapshotTestTab(
        id: "folder-tab",
        spaceID: space.id,
        title: "Folder Tab",
        urlString: "https://folder.example",
        placement: .spacePinned,
        pinnedFolderID: folder.id,
    )
    let activeTab = browserSidebarSnapshotTestTab(
        id: "active-tab",
        spaceID: space.id,
        title: "Active Tab",
        urlString: "https://active.example",
        placement: .temporary,
    )
    let snapshot = BrowserSidebarSnapshot(
        spaces: [space],
        selectedSpaceID: space.id,
        activeSpace: space,
        isActiveSpacePinnedSectionCollapsed: false,
        allTabs: [folderTab, activeTab],
        pinnedTabFolders: [folder],
        appTabs: [],
        spacePinnedTabs: [folderTab],
        temporaryTabs: [activeTab],
        selectedTabID: activeTab.id,
        archivableTabIDs: [],
        canGoBack: false,
        canGoForward: false,
        canStopLoading: false,
        canReload: false,
    )

    let rows = snapshot.visiblePinnedRows(
        in: space.id,
        revealedTabIDsByFolderID: [folder.id: [folderTab.id]],
    )

    #expect(rows.map(\.id) == [
        "folder-\(folder.id)",
        "tab-\(folderTab.id)",
    ])
    // The folder's icon marks the tab shown under it.
    guard case .folder(let shown) = rows.first,
          case .folder(let closed) = snapshot.visiblePinnedRows(in: space.id).first
    else {
        Issue.record("The folder comes first")
        return
    }
    #expect(shown.showsOpenTabs)
    #expect(!closed.showsOpenTabs)
}

@Test func collapsedPinnedFolderShowsSelectedChildWithoutRevealedState() {
    let space = BrowserChromeModel.Space(
        id: "space",
        title: "Space",
        systemImageName: "square.grid.2x2",
        isPinnedSectionCollapsed: false,
        selectedTabID: "folder-tab",
    )
    let folder = BrowserChromeModel.PinnedTabFolder(
        id: "folder",
        spaceID: space.id,
        parentFolderID: nil,
        title: "Folder",
        systemImageName: nil,
        isExpanded: false,
    )
    let folderTab = browserSidebarSnapshotTestTab(
        id: "folder-tab",
        spaceID: space.id,
        title: "Folder Tab",
        urlString: "https://folder.example",
        placement: .spacePinned,
        pinnedFolderID: folder.id,
    )
    let otherFolderTab = browserSidebarSnapshotTestTab(
        id: "other-folder-tab",
        spaceID: space.id,
        title: "Other Folder Tab",
        urlString: "https://other.example",
        placement: .spacePinned,
        pinnedFolderID: folder.id,
    )
    let snapshot = BrowserSidebarSnapshot(
        spaces: [space],
        selectedSpaceID: space.id,
        activeSpace: space,
        isActiveSpacePinnedSectionCollapsed: false,
        allTabs: [folderTab, otherFolderTab],
        pinnedTabFolders: [folder],
        appTabs: [],
        spacePinnedTabs: [folderTab, otherFolderTab],
        temporaryTabs: [],
        selectedTabID: folderTab.id,
        archivableTabIDs: [],
        canGoBack: false,
        canGoForward: false,
        canStopLoading: false,
        canReload: false,
    )

    let rows = snapshot.visiblePinnedRows(in: space.id)

    #expect(rows.map(\.id) == [
        "folder-\(folder.id)",
        "tab-\(folderTab.id)",
    ])
}

private func browserSidebarSnapshotTestTab(
    id: String,
    spaceID: String,
    title: String,
    urlString: String,
    placement: BrowserTabPlacement,
    pinnedFolderID: String? = nil,
) -> BrowserChromeModel.Tab {
    BrowserChromeModel.Tab(
        id: id,
        syncID: id,
        spaceID: spaceID,
        title: title,
        userTitleOverride: nil,
        urlString: urlString,
        faviconURLString: nil,
        placement: placement,
        pinnedFolderID: pinnedFolderID,
        lastActivityAt: Date(timeIntervalSince1970: 0),
    )
}

/// A snapshot works out its pinned rows once per request: asking again, from a copy or
/// with other revealed tabs, gives the same rows a fresh snapshot gives.
@Test func pinnedRowsKeptForASnapshotMatchFreshlyWorkedOutRows() {
    let space = BrowserChromeModel.Space(
        id: "space",
        title: "Space",
        systemImageName: "square.grid.2x2",
        isPinnedSectionCollapsed: false,
        selectedTabID: "loose",
    )
    let folder = BrowserChromeModel.PinnedTabFolder(
        id: "folder",
        spaceID: space.id,
        parentFolderID: nil,
        title: "Folder",
        systemImageName: nil,
        isExpanded: false,
    )
    let inside = browserSidebarSnapshotTestTab(
        id: "inside",
        spaceID: space.id,
        title: "Inside",
        urlString: "https://inside.example",
        placement: .spacePinned,
        pinnedFolderID: folder.id,
    )
    let loose = browserSidebarSnapshotTestTab(
        id: "loose",
        spaceID: space.id,
        title: "Loose",
        urlString: "https://loose.example",
        placement: .spacePinned,
    )
    func makeSnapshot() -> BrowserSidebarSnapshot {
        BrowserSidebarSnapshot(
            spaces: [space],
            selectedSpaceID: space.id,
            activeSpace: space,
            isActiveSpacePinnedSectionCollapsed: false,
            allTabs: [inside, loose],
            pinnedTabFolders: [folder],
            appTabs: [],
            spacePinnedTabs: [inside, loose],
            temporaryTabs: [],
            selectedTabID: loose.id,
            archivableTabIDs: [],
            canGoBack: false,
            canGoForward: false,
            canStopLoading: false,
            canReload: false,
        )
    }
    let snapshot = makeSnapshot()
    let closed = snapshot.visiblePinnedRows(in: space.id)
    #expect(closed.map(\.id) == ["folder-\(folder.id)", "tab-\(loose.id)"])
    var copy = snapshot
    copy.tabIcons = [loose.id: "star"]
    #expect(copy.visiblePinnedRows(in: space.id) == closed)
    let revealed = copy.visiblePinnedRows(in: space.id, revealedTabIDsByFolderID: [folder.id: [inside.id]])
    #expect(revealed.map(\.id) == ["folder-\(folder.id)", "tab-\(inside.id)", "tab-\(loose.id)"])
    #expect(revealed == makeSnapshot().visiblePinnedRows(
        in: space.id,
        revealedTabIDsByFolderID: [folder.id: [inside.id]],
    ))
    #expect(snapshot == makeSnapshot(), "What a snapshot keeps does not change how it compares")
}
