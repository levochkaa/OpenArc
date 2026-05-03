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
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .pinned,
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
        ) == BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 0)
    )
    #expect(
        resolver.target(
            for: CGPoint(x: 30, y: 74),
            rowFrames: rowFrames,
            emptySectionFrames: [],
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 2)
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
                    section: .pinned,
                    frame: CGRect(x: 0, y: 0, width: 200, height: 14)
                ),
            ],
            canMoveToTarget: { _ in true }
        ) == BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 0)
    )
}

@Test
func tabFrameSynchronizerDropsFramesFromPreviousSectionAfterMove() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .pinned,
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
        pinnedTabIDs: ["tab-1", "tab-3"],
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
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-2": BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .pinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    let synchronizedFrames = BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
        rowFrames,
        pinnedTabIDs: ["tab-2", "tab-1"],
        temporaryTabIDs: []
    )

    #expect(synchronizedFrames.isEmpty)
}

@Test
func tabFrameSynchronizerEstimatesDropFramesForFreshlyMovedTab() {
    let rowFrames = [
        "tab-1": BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-2": BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .pinned,
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
    let pinnedTabIDs = ["tab-1", "tab-3", "tab-2"]

    let synchronizedFrames = BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
        rowFrames,
        pinnedTabIDs: pinnedTabIDs,
        temporaryTabIDs: []
    )
    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        emptySectionFrames: [],
        pinnedTabIDs: pinnedTabIDs,
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(BrowserSidebarTabFrameSynchronizer.sortedRowFrameList(synchronizedFrames).map(\.tabID) == ["tab-1"])
    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-3",
            section: .pinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .pinned,
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
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        "tab-2": BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .pinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]
    let pinnedTabIDs = ["tab-2", "tab-1"]

    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        emptySectionFrames: [],
        pinnedTabIDs: pinnedTabIDs,
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-2",
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .pinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
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
                section: .pinned,
                frame: CGRect(x: 0, y: 0, width: 200, height: 14)
            ),
        ],
        pinnedTabIDs: ["tab-1"],
        temporaryTabIDs: [],
        rowHeight: 36,
        rowSpacing: 5
    )

    #expect(dropRowFrames == [
        BrowserSidebarTabRowFrame(
            tabID: "tab-1",
            section: .pinned,
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
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ]

    let dropRowFrames = BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
        rowFrames,
        fallbackRowFrames: fallbackRowFrames,
        emptySectionFrames: [],
        pinnedTabIDs: ["tab-1"],
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
            section: .pinned,
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
            pinnedTabIDs: [],
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
    let target = BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 1)
    let rowFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "pinned-1",
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .pinned,
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
            section: .pinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 1),
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
            section: .pinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
        BrowserSidebarTabRowFrame(
            tabID: "pinned-2",
            section: .pinned,
            sectionIndex: 1,
            frame: CGRect(x: 0, y: 41, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 2),
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
