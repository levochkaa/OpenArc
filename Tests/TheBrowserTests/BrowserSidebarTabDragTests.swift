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
func tabDropIndicatorResolverDrawsOnlyOneLineBetweenRows() {
    let resolver = BrowserSidebarTabDropIndicatorResolver()
    let target = BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: 1)

    #expect(
        resolver.edge(
            for: .pinned,
            sectionIndex: 0,
            target: target
        ) == .bottom
    )
    #expect(
        resolver.edge(
            for: .pinned,
            sectionIndex: 1,
            target: target
        ) == nil
    )
}

@Test
func tabDropIndicatorResolverUsesTopEdgeOnlyAtSectionStart() {
    let resolver = BrowserSidebarTabDropIndicatorResolver()
    let target = BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: 0)

    #expect(
        resolver.edge(
            for: .temporary,
            sectionIndex: 0,
            target: target
        ) == .top
    )
    #expect(
        resolver.edge(
            for: .temporary,
            sectionIndex: 1,
            target: target
        ) == nil
    )
}
