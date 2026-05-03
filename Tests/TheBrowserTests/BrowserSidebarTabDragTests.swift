import CoreGraphics
import Testing

@Test
func tabDragResolverSnapsToNearestReachableRowEdge() {
    let resolver = BrowserSidebarTabDragTargetResolver(
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "pinned-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "temporary-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 3),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: 0)
    )
    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 74),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: 2)
    )
    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 113),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0)
    )
}

@Test
func tabDragResolverUsesEmptySectionFrames() {
    let resolver = BrowserSidebarTabDragTargetResolver(
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )

    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 8),
            rowFrames: [],
            emptySectionFrames: [
                BrowserSidebarEmptySectionFrame(
                    section: .spacePinned,
                    frame: CGRect(x: 0, y: 0, width: 200, height: 14)
                ),
            ],
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: 0)
    )
}

@Test
func tabFrameSynchronizerDropsFramesFromPreviousSectionAfterMove() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-3": BrowserSidebarTabRowFrame(
            tabID: "tab-3",
            section: .temporary,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
    ]

    let synchronizedFrames = BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
        rowFrames,
        spacePinnedTabIDs: ["tab-1", "tab-3"],
        temporaryTabIDs: ["tab-2"]
    )

    #expect(synchronizedFrames["tab-1"] == rowFrames["tab-1"])
    #expect(synchronizedFrames["tab-3"] == nil)
    #expect(BrowserSidebarTabFrameSynchronizer.sortedRowFrameList(synchronizedFrames).map(\.tabID) == ["tab-1"])
}

@Test
func tabFrameSynchronizerDropsFramesWithPreviousSectionIndexAfterReorder() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-2": BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    let synchronizedFrames = BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
        rowFrames,
        spacePinnedTabIDs: ["tab-2", "tab-1"],
        temporaryTabIDs: []
    )

    #expect(synchronizedFrames.isEmpty)
}

@Test
func tabFrameSynchronizerEstimatesDropFramesForFreshlyMovedTab() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-2": BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
        "tab-3": BrowserSidebarTabRowFrame(
            tabID: "tab-3",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
    ]
    let spacePinnedTabIDs = ["tab-1", "tab-3", "tab-2"]

    let synchronizedFrames = BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
        rowFrames,
        spacePinnedTabIDs: spacePinnedTabIDs,
        temporaryTabIDs: []
    )
    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        emptySectionFrames: [],
        spacePinnedTabIDs: spacePinnedTabIDs,
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(BrowserSidebarTabFrameSynchronizer.sortedRowFrameList(synchronizedFrames).map(\.tabID) == ["tab-1"])
    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-3",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .spacePinned,
            sectionIndex: 2,
            frame: CGRect(x: 0, y: 82, width: 200, height: 36)
        ),
    ])
}

@Test
func tabFrameSynchronizerEstimatesDropFramesAfterSameSectionReorder() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-2": BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]
    let spacePinnedTabIDs = ["tab-2", "tab-1"]

    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        emptySectionFrames: [],
        spacePinnedTabIDs: spacePinnedTabIDs,
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ])
}

@Test
func tabFrameSynchronizerAllowsDuplicateFallbackFramesDuringCrossSectionDrag() {
    let fallbackRowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ]

    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        [:],
        fallbackRowFrames: fallbackRowFrames,
        emptySectionFrames: [],
        spacePinnedTabIDs: ["tab-1"],
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ])
}

@Test
func tabFrameSynchronizerUsesEmptySectionAnchorForFirstDropFrame() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
    ]

    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        emptySectionFrames: [
            BrowserSidebarEmptySectionFrame(
                section: .spacePinned,
                frame: CGRect(x: 0, y: 0, width: 200, height: 14)
            ),
        ],
        spacePinnedTabIDs: ["tab-1"],
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ])
}

@Test
func tabFrameSynchronizerUsesFallbackDropFrameWhenPreferencesLag() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
    ]
    let fallbackRowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ]

    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        fallbackRowFrames: fallbackRowFrames,
        emptySectionFrames: [],
        spacePinnedTabIDs: ["tab-1"],
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(dropRowFrames == fallbackRowFrames)
}

@Test
func tabFrameSynchronizerKeepsOnlyCurrentlyEmptySectionFrames() {
    let emptySectionFrames = [
        BrowserSidebarEmptySectionFrame(
            section: .spacePinned,
            frame: CGRect(x: 0, y: 0, width: 200, height: 14)
        ),
        BrowserSidebarEmptySectionFrame(
            section: .temporary,
            frame: CGRect(x: 0, y: 112, width: 200, height: 14)
        ),
    ]

    #expect(
        BrowserSidebarTabFrameSynchronizer.synchronizedEmptySectionFrames(
            emptySectionFrames,
            spacePinnedTabIDs: [],
            temporaryTabIDs: ["tab-1"]
        ) == [emptySectionFrames[0]]
    )
}

@Test
func tabDragResolverIgnoresFarAndInvalidTargets() {
    let resolver = BrowserSidebarTabDragTargetResolver(
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "temporary-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.target(
            for: CGPoint(x: 400, y: 4),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            canMoveToTarget: { _ in true }
        ) == nil
    )
    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 4),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            canMoveToTarget: { _ in false }
        ) == nil
    )
}

@Test
func tabDropIndicatorFrameResolverDrawsOnlyOneLineBetweenRows() {
    let resolver = BrowserSidebarTabDropIndicatorFrameResolver()
    let target = BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: 1)
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "pinned-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: target,
            rowFrames: rowFrames,
            emptySectionFrames: [],
            horizontalInset: 6,
            thickness: 2
        ) == CGRect(x: 6, y: 35, width: 188, height: 2)
    )
}

@Test
func tabDropIndicatorFrameResolverFallsBackToFollowingRowTopEdge() {
    let resolver = BrowserSidebarTabDropIndicatorFrameResolver()
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: 1),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            horizontalInset: 6,
            thickness: 2
        ) == CGRect(x: 6, y: 40, width: 188, height: 2)
    )
}

@Test
func tabDropIndicatorFrameResolverUsesPreviousRowBottomAtSectionEnd() {
    let resolver = BrowserSidebarTabDropIndicatorFrameResolver()
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "pinned-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .spacePinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: 2),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            horizontalInset: 6,
            thickness: 2
        ) == CGRect(x: 6, y: 76, width: 188, height: 2)
    )
}

@Test
func tabDropIndicatorFrameResolverUsesTopEdgeOnlyAtSectionStart() {
    let resolver = BrowserSidebarTabDropIndicatorFrameResolver()
    let target = BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0)
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "temporary-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 112, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "temporary-2",
            section: .temporary,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 153, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: target,
            rowFrames: rowFrames,
            emptySectionFrames: [],
            horizontalInset: 6,
            thickness: 2
        ) == CGRect(x: 6, y: 111, width: 188, height: 2)
    )
}

@Test
func appTabGridLayoutStretchesOneToThreeItemsAcrossOneRow() {
    let layout = BrowserSidebarAppTabGridLayout(spacing: 5)

    #expect(layout.frames(for: 1, availableWidth: 200) == [
        CGRect(x: 0, y: 0, width: 200, height: 46.25),
    ])
    #expect(layout.frames(for: 2, availableWidth: 200) == [
        CGRect(x: 0, y: 0, width: 97.5, height: 46.25),
        CGRect(x: 102.5, y: 0, width: 97.5, height: 46.25),
    ])
    #expect(layout.frames(for: 3, availableWidth: 200) == [
        CGRect(x: 0, y: 0, width: 63.333333333333336, height: 46.25),
        CGRect(x: 68.33333333333334, y: 0, width: 63.333333333333336, height: 46.25),
        CGRect(x: 136.66666666666669, y: 0, width: 63.333333333333336, height: 46.25),
    ])
}

@Test
func appTabGridLayoutUsesFourColumnsAndTwoRowsForFiveToEightItems() {
    let layout = BrowserSidebarAppTabGridLayout(spacing: 5)

    #expect(layout.frames(for: 4, availableWidth: 200) == [
        CGRect(x: 0, y: 0, width: 46.25, height: 46.25),
        CGRect(x: 51.25, y: 0, width: 46.25, height: 46.25),
        CGRect(x: 102.5, y: 0, width: 46.25, height: 46.25),
        CGRect(x: 153.75, y: 0, width: 46.25, height: 46.25),
    ])
    #expect(layout.frames(for: 5, availableWidth: 200).last == CGRect(x: 0, y: 51.25, width: 200, height: 46.25))
    #expect(layout.frames(for: 8, availableWidth: 200).last == CGRect(x: 153.75, y: 51.25, width: 46.25, height: 46.25))
    #expect(layout.height(for: 8, availableWidth: 200) == 97.5)
}

@Test
func appTabDropFrameListUsesContainerFrame() {
    let frames = BrowserSidebarAppTabFrameSynchronizer.dropFrameList(
        containerFrame: CGRect(x: 10, y: 20, width: 200, height: 100),
        appTabIDs: ["tab-1", "tab-2"],
        spacing: 5
    )

    #expect(frames == [
        BrowserSidebarAppTabFrame(
            tabID: "tab-1",
            sectionIndex: 0,
            frame: CGRect(x: 10, y: 20, width: 97.5, height: 46.25)
        ),
        BrowserSidebarAppTabFrame(
            tabID: "tab-2",
            sectionIndex: 1,
            frame: CGRect(x: 112.5, y: 20, width: 97.5, height: 46.25)
        ),
    ])
}

@Test
func tabDragResolverUsesEmptyAppTabContainerFrame() {
    let resolver = BrowserSidebarTabDragTargetResolver(
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )

    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 8),
            rowFrames: [],
            emptySectionFrames: [],
            appTabContainerFrame: CGRect(x: 0, y: 0, width: 200, height: 14),
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .app, sectionIndex: 0)
    )
}

@Test
func tabDragResolverFindsAppTabGridInsertionIndex() {
    let resolver = BrowserSidebarTabDragTargetResolver(
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )
    let appTabFrames = BrowserSidebarAppTabFrameSynchronizer.dropFrameList(
        containerFrame: CGRect(x: 0, y: 0, width: 200, height: 100),
        appTabIDs: ["tab-1", "tab-2", "tab-3", "tab-4"],
        spacing: 5
    )

    #expect(
        resolver.target(
            for: CGPoint(x: 10, y: 10),
            rowFrames: [],
            emptySectionFrames: [],
            appTabFrames: appTabFrames,
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .app, sectionIndex: 0)
    )
    #expect(
        resolver.target(
            for: CGPoint(x: 130, y: 10),
            rowFrames: [],
            emptySectionFrames: [],
            appTabFrames: appTabFrames,
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .app, sectionIndex: 3)
    )
}

@Test
func tabDragResolverSwitchesBetweenGridAndRows() {
    let resolver = BrowserSidebarTabDragTargetResolver(
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )
    let appTabFrames = BrowserSidebarAppTabFrameSynchronizer.dropFrameList(
        containerFrame: CGRect(x: 0, y: 0, width: 200, height: 60),
        appTabIDs: ["tab-1"],
        spacing: 5
    )
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "temporary-1",
            section: .temporary,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 90, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.target(
            for: CGPoint(x: 40, y: 20),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            appTabFrames: appTabFrames,
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .app, sectionIndex: 0)
    )
    #expect(
        resolver.target(
            for: CGPoint(x: 40, y: 91),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            appTabFrames: appTabFrames,
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0)
    )
}
