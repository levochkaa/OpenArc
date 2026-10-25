// BrowserSidebarPinnedTabFolderCreationSelectionTests.swift

import Testing

@Test func pinnedTabFolderCreationUsesClickedAndSelectedTabsWhenMultipleAreSelected() {
    let selection = BrowserSidebarPinnedTabFolderCreationSelection(
        clickedTabID: "clicked",
        activeTabID: nil,
        selectedTabIDs: ["selected-1", "selected-2"],
        listTabIDs: ["clicked", "selected-1", "selected-2"],
    )

    #expect(selection.tabIDs == ["clicked", "selected-1", "selected-2"])
}

@Test func pinnedTabFolderCreationUsesClickedAndSelectedTabsWhenSelectionIsNotMultiSelect() {
    let selection = BrowserSidebarPinnedTabFolderCreationSelection(
        clickedTabID: "clicked",
        activeTabID: nil,
        selectedTabIDs: ["selected-1"],
        listTabIDs: ["clicked", "selected-1"],
    )

    #expect(selection.tabIDs == ["clicked", "selected-1"])
}

@Test func pinnedTabFolderCreationIncludesActiveListTabWithSelection() {
    let selection = BrowserSidebarPinnedTabFolderCreationSelection(
        clickedTabID: "selected",
        activeTabID: "active",
        selectedTabIDs: ["selected"],
        listTabIDs: ["active", "selected"],
    )

    #expect(selection.tabIDs == ["active", "selected"])
}

@Test func pinnedTabFolderCreationIgnoresStaleSelectedTabsOutsideList() {
    let selection = BrowserSidebarPinnedTabFolderCreationSelection(
        clickedTabID: "clicked",
        activeTabID: "stale-active",
        selectedTabIDs: ["selected-1", "stale"],
        listTabIDs: ["clicked", "selected-1"],
    )

    #expect(selection.tabIDs == ["clicked", "selected-1"])
}

@Test func pinnedTabFolderCreationIgnoresActiveGridTabOutsideList() {
    let selection = BrowserSidebarPinnedTabFolderCreationSelection(
        clickedTabID: "clicked",
        activeTabID: "app-tab",
        selectedTabIDs: [],
        listTabIDs: ["clicked"],
    )

    #expect(selection.tabIDs == ["clicked"])
}
