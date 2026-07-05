import CoreGraphics
import Testing

private func makeTabDropLayout(
    rowFrames: [BrowserSidebarTabRowFrame] = [],
    emptySectionFrames: [BrowserSidebarEmptySectionFrame] = [],
    pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame] = [],
    spaceHeaderFrames: [BrowserSidebarSpaceHeaderFrame] = [],
    appTabFrames: [BrowserSidebarAppTabFrame] = [],
    appTabContainerFrame: CGRect? = nil
) -> BrowserSidebarTabDropLayout {
    BrowserSidebarTabDropLayout(
        rowFrames: rowFrames,
        emptySectionFrames: emptySectionFrames,
        pinnedFolderFrames: pinnedFolderFrames,
        spaceHeaderFrames: spaceHeaderFrames,
        appTabFrames: appTabFrames,
        appTabContainerFrame: appTabContainerFrame,
        horizontalInset: 6,
        thickness: 2,
        verticalSnapDistance: 24,
        horizontalTolerance: 48
    )
}

@Test func tabDragResolverSnapsToNearestReachableRowEdge() {
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

@Test func tabDropLayoutProposalUsesTemporarySlotWhenPointerIsInsideTemporaryRows() {
    let layout = makeTabDropLayout(
        rowFrames: [
            BrowserSidebarTabRowFrame(
                tabID: "pinned-1",
                section: .spacePinned,
                sectionIndex: 0,
                frame: CGRect(x: 0, y: 0, width: 200, height: 36)
            ),
            BrowserSidebarTabRowFrame(
                tabID: "temporary-1",
                section: .temporary,
                sectionIndex: 0,
                frame: CGRect(x: 0, y: 112, width: 200, height: 36)
            ),
        ]
    )

    let proposal = layout.proposal(
        for: CGPoint(x: 30, y: 113),
        canMoveToTarget: { _ in true }
    )

    #expect(proposal?.target == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0))
    #expect(proposal?.indicatorFrame == CGRect(x: 6, y: 111, width: 188, height: 2))
}

@Test func tabDropLayoutProposalDoesNotUseAnimatedFallbackFramesForHitTesting() {
    let staticLayout = makeTabDropLayout(
        rowFrames: [
            BrowserSidebarTabRowFrame(
                tabID: "temporary-1",
                section: .temporary,
                sectionIndex: 0,
                frame: CGRect(x: 0, y: 112, width: 200, height: 36)
            ),
        ],
        emptySectionFrames: [
            BrowserSidebarEmptySectionFrame(
                section: .spacePinned,
                frame: CGRect(x: 0, y: 0, width: 200, height: 0)
            ),
        ]
    )
    let animatedPreviewFrames = [
        BrowserSidebarTabRowFrame(
            tabID: "temporary-1",
            section: .spacePinned,
            sectionIndex: 0,
            frame: CGRect(x: 0, y: 0, width: 200, height: 36)
        ),
    ]

    let proposal = staticLayout.proposal(
        for: CGPoint(x: 30, y: 113),
        canMoveToTarget: { _ in true }
    )

    #expect(animatedPreviewFrames.first?.section == .spacePinned)
    #expect(proposal?.target == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0))
}

@Test func tabDragSessionKeepsPreviousProposalAcrossSubpixelBoundary() {
    let layout = makeTabDropLayout(
        rowFrames: [
            BrowserSidebarTabRowFrame(
                tabID: "temporary-1",
                section: .temporary,
                sectionIndex: 0,
                frame: CGRect(x: 0, y: 0, width: 200, height: 36)
            ),
            BrowserSidebarTabRowFrame(
                tabID: "temporary-2",
                section: .temporary,
                sectionIndex: 1,
                frame: CGRect(x: 0, y: 41, width: 200, height: 36)
            ),
        ]
    )
    var session = BrowserSidebarTabDragSession(layout: layout, hysteresisDistance: 3)

    let firstProposal = session.proposal(
        for: CGPoint(x: 30, y: 17.9),
        canMoveToTarget: { _ in true }
    )
    let jitterProposal = session.proposal(
        for: CGPoint(x: 30, y: 18.2),
        canMoveToTarget: { _ in true }
    )
    let freshProposal = layout.proposal(
        for: CGPoint(x: 30, y: 18.2),
        canMoveToTarget: { _ in true }
    )

    #expect(firstProposal?.target == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0))
    #expect(jitterProposal?.target == firstProposal?.target)
    #expect(freshProposal?.target == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 1))
}

@Test func tabDropProposalUsesSameTargetAndIndicatorFrame() {
    let layout = makeTabDropLayout(
        rowFrames: [
            BrowserSidebarTabRowFrame(
                tabID: "temporary-1",
                section: .temporary,
                sectionIndex: 0,
                frame: CGRect(x: 0, y: 0, width: 200, height: 36)
            ),
            BrowserSidebarTabRowFrame(
                tabID: "temporary-2",
                section: .temporary,
                sectionIndex: 1,
                frame: CGRect(x: 0, y: 41, width: 200, height: 36)
            ),
        ]
    )

    let proposal = layout.proposal(
        for: CGPoint(x: 30, y: 40),
        canMoveToTarget: { _ in true }
    )

    #expect(proposal?.target == BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 1))
    #expect(proposal?.indicatorFrame == CGRect(x: 6, y: 35, width: 188, height: 2))
    #expect(proposal?.previewFrame == CGRect(x: 0, y: 41, width: 200, height: 36))
}

@Test func tabDropLayoutResolvesPinnedFolderRootAndChildSlots() {
    let childPreviewFrame = CGRect(x: 16, y: 40, width: 184, height: 36)
    let layout = makeTabDropLayout(
        pinnedFolderFrames: [
            BrowserSidebarPinnedFolderRowFrame(
                folderID: "folder-1",
                firstSectionIndex: 2,
                afterSectionIndex: 5,
                childCount: 3,
                spaceID: "space-1",
                frame: CGRect(x: 0, y: 40, width: 200, height: 36),
                childPreviewFrame: childPreviewFrame
            ),
        ]
    )

    let beforeProposal = layout.proposal(
        for: CGPoint(x: 30, y: 41),
        canMoveToTarget: { _ in true }
    )
    let folderProposal = layout.proposal(
        for: CGPoint(x: 30, y: 58),
        canMoveToTarget: { _ in true }
    )
    let afterProposal = layout.proposal(
        for: CGPoint(x: 30, y: 82),
        canMoveToTarget: { _ in true }
    )
    let bottomEdgeProposal = layout.proposal(
        for: CGPoint(x: 30, y: 75),
        canMoveToTarget: { _ in true }
    )

    #expect(beforeProposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 2,
        spaceID: "space-1"
    ))
    #expect(beforeProposal?.indicatorFrame == CGRect(x: 6, y: 39, width: 188, height: 2))
    #expect(folderProposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 0,
        spaceID: "space-1",
        pinnedFolderID: "folder-1"
    ))
    #expect(folderProposal?.indicatorFrame == nil)
    #expect(folderProposal?.previewFrame == childPreviewFrame)
    #expect(bottomEdgeProposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 0,
        spaceID: "space-1",
        pinnedFolderID: "folder-1"
    ))
    #expect(bottomEdgeProposal?.indicatorFrame == nil)
    #expect(afterProposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 5,
        spaceID: "space-1"
    ))
    #expect(afterProposal?.indicatorFrame == CGRect(x: 6, y: 75, width: 188, height: 2))
}

@Test func tabDropLayoutHighlightsPinnedFolderForFirstChildSlotWithoutAdjacentLine() {
    let folderFrame = CGRect(x: 0, y: 40, width: 200, height: 36)
    let childPreviewFrame = CGRect(x: 16, y: 40, width: 184, height: 36)
    let layout = makeTabDropLayout(
        rowFrames: [
            BrowserSidebarTabRowFrame(
                tabID: "child-1",
                section: .spacePinned,
                sectionIndex: 2,
                spaceID: "space-1",
                pinnedFolderID: "folder-1",
                folderChildIndex: 0,
                frame: CGRect(x: 16, y: 81, width: 184, height: 36)
            ),
        ],
        pinnedFolderFrames: [
            BrowserSidebarPinnedFolderRowFrame(
                folderID: "folder-1",
                firstSectionIndex: 2,
                afterSectionIndex: 3,
                childCount: 1,
                spaceID: "space-1",
                frame: folderFrame,
                childPreviewFrame: childPreviewFrame
            ),
        ]
    )

    let proposal = layout.proposal(
        for: CGPoint(x: 30, y: 82),
        canMoveToTarget: { _ in true }
    )

    #expect(proposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 0,
        spaceID: "space-1",
        pinnedFolderID: "folder-1"
    ))
    #expect(proposal?.indicatorFrame == nil)
    #expect(proposal?.previewFrame == childPreviewFrame)
}

@Test func tabDropLayoutSpaceHeaderDropsToTopOfSpacePinnedSection() {
    let layout = makeTabDropLayout(
        rowFrames: [
            BrowserSidebarTabRowFrame(
                tabID: "pinned-1",
                section: .spacePinned,
                sectionIndex: 0,
                spaceID: "space-1",
                frame: CGRect(x: 0, y: 46, width: 200, height: 36)
            ),
        ],
        spaceHeaderFrames: [
            BrowserSidebarSpaceHeaderFrame(
                spaceID: "space-1",
                frame: CGRect(x: 0, y: 0, width: 200, height: 36)
            ),
        ]
    )

    let proposal = layout.proposal(
        for: CGPoint(x: 30, y: 18),
        canMoveToTarget: { _ in true }
    )
    let listTopProposal = layout.proposal(
        for: CGPoint(x: 30, y: 46),
        canMoveToTarget: { _ in true }
    )

    #expect(proposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 0,
        spaceID: "space-1"
    ))
    #expect(proposal?.indicatorFrame == nil)
    #expect(listTopProposal?.target == BrowserSidebarTabDropTarget(
        section: .spacePinned,
        sectionIndex: 0,
        spaceID: "space-1"
    ))
    #expect(listTopProposal?.indicatorFrame == CGRect(x: 6, y: 45, width: 188, height: 2))
}

@Test func tabDragPreviewKeepsOriginalPointerOffsetWhenSizeChanges() {
    var preview = BrowserSidebarTabDragPreviewState(
        tabID: "tab-1",
        sourceFrame: CGRect(x: 0, y: 100, width: 200, height: 36),
        location: CGPoint(x: 40, y: 110)
    )

    preview.update(location: CGPoint(x: 60, y: 130), size: CGSize(width: 120, height: 36))

    #expect(preview.center == CGPoint(x: 120, y: 138))
}

@Test func tabDragResolverUsesEmptySectionFrames() {
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

@Test func tabFrameSynchronizerDropsFramesFromPreviousSectionAfterMove() {
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

@Test func tabFrameSynchronizerDropsFramesWithPreviousSectionIndexAfterReorder() {
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

@Test func tabFrameSynchronizerEstimatesDropFramesForFreshlyMovedTab() {
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

@Test func tabFrameSynchronizerEstimatesDropFramesAfterSameSectionReorder() {
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

@Test func tabFrameSynchronizerAllowsDuplicateFallbackFramesDuringCrossSectionDrag() {
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

@Test func tabFrameSynchronizerUsesEmptySectionAnchorForFirstDropFrame() {
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

@Test func tabFrameSynchronizerUsesFallbackDropFrameWhenPreferencesLag() {
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

@Test func tabFrameSynchronizerKeepsOnlyCurrentlyEmptySectionFrames() {
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

@Test func tabDragResolverIgnoresFarAndInvalidTargets() {
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

@Test func tabDropIndicatorFrameResolverDrawsOnlyOneLineBetweenRows() {
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

@Test func tabDropIndicatorFrameResolverFallsBackToFollowingRowTopEdge() {
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

@Test func tabDropIndicatorFrameResolverUsesPreviousRowBottomAtSectionEnd() {
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

@Test func tabDropIndicatorFrameResolverUsesTopEdgeOnlyAtSectionStart() {
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

@Test func tabDropIndicatorFrameResolverDoesNotDrawLineForPinnedFolderBodyTarget() {
    let resolver = BrowserSidebarTabDropIndicatorFrameResolver()
    let pinnedFolderFrames = [
        BrowserSidebarPinnedFolderRowFrame(
            folderID: "folder-1",
            firstSectionIndex: 2,
            afterSectionIndex: 5,
            childCount: 3,
            spaceID: "space-1",
            frame: CGRect(x: 0, y: 40, width: 200, height: 36)
        ),
    ]

    #expect(
        resolver.frame(
            for: BrowserSidebarTabDropTarget(
                section: .spacePinned,
                sectionIndex: 3,
                spaceID: "space-1",
                pinnedFolderID: "folder-1"
            ),
            rowFrames: [],
            emptySectionFrames: [],
            pinnedFolderFrames: pinnedFolderFrames,
            horizontalInset: 6,
            thickness: 2
        ) == nil
    )
    #expect(
        resolver.frame(
            for: BrowserSidebarTabDropTarget(
                section: .spacePinned,
                sectionIndex: 0,
                spaceID: "space-1",
                pinnedFolderID: "folder-1"
            ),
            rowFrames: [
                BrowserSidebarTabRowFrame(
                    tabID: "child-1",
                    section: .spacePinned,
                    sectionIndex: 2,
                    spaceID: "space-1",
                    pinnedFolderID: "folder-1",
                    folderChildIndex: 0,
                    frame: CGRect(x: 16, y: 81, width: 184, height: 36)
                ),
            ],
            emptySectionFrames: [],
            pinnedFolderFrames: pinnedFolderFrames,
            horizontalInset: 6,
            thickness: 2
        ) == nil
    )
}

@Test func appTabGridLayoutStretchesOneToThreeItemsAcrossOneRow() {
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

@Test func appTabGridLayoutUsesFourColumnsAndTwoRowsForFiveToEightItems() {
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

@Test func appTabDropFrameListUsesContainerFrame() {
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

@Test func tabDragResolverUsesEmptyAppTabContainerFrame() {
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

@Test func tabDragResolverFindsAppTabGridInsertionIndex() {
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

@Test func tabDragResolverSwitchesBetweenGridAndRows() {
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
