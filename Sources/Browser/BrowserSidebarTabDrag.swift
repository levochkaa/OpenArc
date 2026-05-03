import CoreGraphics

enum BrowserSidebarTabSection: Equatable {
    case pinned
    case temporary

    var isPinned: Bool {
        switch self {
        case .pinned:
            true
        case .temporary:
            false
        }
    }

    var sortPriority: Int {
        switch self {
        case .pinned:
            0
        case .temporary:
            1
        }
    }
}

struct BrowserSidebarTabDropTarget: Equatable {
    let section: BrowserSidebarTabSection
    let sectionIndex: Int
}

struct BrowserSidebarTabRowFrame: Equatable {
    let tabID: String
    let section: BrowserSidebarTabSection
    let sectionIndex: Int
    let frame: CGRect
}

struct BrowserSidebarEmptySectionFrame: Equatable {
    let section: BrowserSidebarTabSection
    let frame: CGRect

    var target: BrowserSidebarTabDropTarget {
        BrowserSidebarTabDropTarget(section: section, sectionIndex: 0)
    }
}

struct BrowserSidebarTabFrameSynchronizer {
    static func synchronizedRowFrames(
        _ rowFrames: [String: BrowserSidebarTabRowFrame],
        pinnedTabIDs: [String],
        temporaryTabIDs: [String]
    ) -> [String: BrowserSidebarTabRowFrame] {
        let expectedLocations = expectedRowLocations(
            pinnedTabIDs: pinnedTabIDs,
            temporaryTabIDs: temporaryTabIDs
        )

        return rowFrames.reduce(into: [:]) { synchronizedRowFrames, item in
            let tabID = item.key
            let rowFrame = item.value

            guard
                rowFrame.tabID == tabID,
                let expectedLocation = expectedLocations[tabID],
                rowFrame.section == expectedLocation.section,
                rowFrame.sectionIndex == expectedLocation.sectionIndex
            else {
                return
            }

            synchronizedRowFrames[tabID] = rowFrame
        }
    }

    static func sortedRowFrameList(
        _ rowFrames: [String: BrowserSidebarTabRowFrame]
    ) -> [BrowserSidebarTabRowFrame] {
        rowFrames.values.sorted { lhs, rhs in
            if lhs.section.sortPriority == rhs.section.sortPriority {
                return lhs.sectionIndex < rhs.sectionIndex
            }

            return lhs.section.sortPriority < rhs.section.sortPriority
        }
    }

    static func synchronizedDropRowFrameList(
        _ rowFrames: [String: BrowserSidebarTabRowFrame],
        fallbackRowFrames: [BrowserSidebarTabRowFrame] = [],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        pinnedTabIDs: [String],
        temporaryTabIDs: [String],
        rowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> [BrowserSidebarTabRowFrame] {
        let pinnedRowFrames = estimatedRowFrames(
            for: .pinned,
            tabIDs: pinnedTabIDs,
            rowFrames: rowFrames,
            fallbackRowFrames: fallbackRowFrames,
            emptySectionFrames: emptySectionFrames,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing
        )
        let temporaryRowFrames = estimatedRowFrames(
            for: .temporary,
            tabIDs: temporaryTabIDs,
            rowFrames: rowFrames,
            fallbackRowFrames: fallbackRowFrames,
            emptySectionFrames: emptySectionFrames,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing
        )

        return pinnedRowFrames + temporaryRowFrames
    }

    static func synchronizedEmptySectionFrames(
        _ emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        pinnedTabIDs: [String],
        temporaryTabIDs: [String]
    ) -> [BrowserSidebarEmptySectionFrame] {
        emptySectionFrames.filter { emptySectionFrame in
            switch emptySectionFrame.section {
            case .pinned:
                pinnedTabIDs.isEmpty
            case .temporary:
                temporaryTabIDs.isEmpty
            }
        }
    }

    private static func expectedRowLocations(
        pinnedTabIDs: [String],
        temporaryTabIDs: [String]
    ) -> [String: BrowserSidebarTabDropTarget] {
        var locations: [String: BrowserSidebarTabDropTarget] = [:]

        for (index, tabID) in pinnedTabIDs.enumerated() {
            locations[tabID] = BrowserSidebarTabDropTarget(section: .pinned, sectionIndex: index)
        }

        for (index, tabID) in temporaryTabIDs.enumerated() {
            locations[tabID] = BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: index)
        }

        return locations
    }

    private static func estimatedRowFrames(
        for section: BrowserSidebarTabSection,
        tabIDs: [String],
        rowFrames: [String: BrowserSidebarTabRowFrame],
        fallbackRowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        rowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> [BrowserSidebarTabRowFrame] {
        guard !tabIDs.isEmpty else {
            return []
        }

        let fallbackRowFramesByID = Dictionary(uniqueKeysWithValues: fallbackRowFrames.map { ($0.tabID, $0) })
        let anchors = tabIDs.enumerated().compactMap { index, tabID -> BrowserSidebarTabDropFrameAnchor? in
            guard
                let rowFrame = synchronizedDropRowFrame(
                    for: tabID,
                    section: section,
                    sectionIndex: index,
                    rowFrames: rowFrames,
                    fallbackRowFrames: fallbackRowFramesByID
                ),
                rowFrame.section == section,
                rowFrame.sectionIndex == index
            else {
                return nil
            }

            return BrowserSidebarTabDropFrameAnchor(sectionIndex: index, frame: rowFrame.frame)
        }

        if !anchors.isEmpty {
            return tabIDs.enumerated().map { index, tabID in
                let anchor = nearestAnchor(to: index, anchors: anchors)
                return rowFrame(
                    tabID: tabID,
                    section: section,
                    sectionIndex: index,
                    anchor: anchor,
                    rowSpacing: rowSpacing
                )
            }
        }

        let candidateRowFrames = tabIDs.flatMap { tabID in
            [rowFrames[tabID], fallbackRowFramesByID[tabID]].compactMap { $0 }
        }
        if let firstSectionFrame = candidateRowFrames
            .filter({ $0.section == section })
            .map(\.frame)
            .sorted(by: { $0.minY < $1.minY })
            .first
        {
            let anchor = BrowserSidebarTabDropFrameAnchor(sectionIndex: 0, frame: firstSectionFrame)
            return tabIDs.enumerated().map { index, tabID in
                rowFrame(
                    tabID: tabID,
                    section: section,
                    sectionIndex: index,
                    anchor: anchor,
                    rowSpacing: rowSpacing
                )
            }
        }

        if let emptySectionFrame = emptySectionFrames.first(where: { $0.section == section })?.frame {
            let firstRowFrame = CGRect(
                x: emptySectionFrame.minX,
                y: emptySectionFrame.minY,
                width: emptySectionFrame.width,
                height: rowHeight
            )
            let anchor = BrowserSidebarTabDropFrameAnchor(sectionIndex: 0, frame: firstRowFrame)
            return tabIDs.enumerated().map { index, tabID in
                rowFrame(
                    tabID: tabID,
                    section: section,
                    sectionIndex: index,
                    anchor: anchor,
                    rowSpacing: rowSpacing
                )
            }
        }

        return []
    }

    private static func synchronizedDropRowFrame(
        for tabID: String,
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        rowFrames: [String: BrowserSidebarTabRowFrame],
        fallbackRowFrames: [String: BrowserSidebarTabRowFrame]
    ) -> BrowserSidebarTabRowFrame? {
        [rowFrames[tabID], fallbackRowFrames[tabID]]
            .compactMap { $0 }
            .first {
                $0.section == section
                    && $0.sectionIndex == sectionIndex
            }
    }

    private static func nearestAnchor(
        to sectionIndex: Int,
        anchors: [BrowserSidebarTabDropFrameAnchor]
    ) -> BrowserSidebarTabDropFrameAnchor {
        anchors.min { lhs, rhs in
            abs(lhs.sectionIndex - sectionIndex) < abs(rhs.sectionIndex - sectionIndex)
        } ?? anchors[0]
    }

    private static func rowFrame(
        tabID: String,
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        anchor: BrowserSidebarTabDropFrameAnchor,
        rowSpacing: CGFloat
    ) -> BrowserSidebarTabRowFrame {
        let rowStride = anchor.frame.height + rowSpacing
        return BrowserSidebarTabRowFrame(
            tabID: tabID,
            section: section,
            sectionIndex: sectionIndex,
            frame: anchor.frame.offsetBy(
                dx: 0,
                dy: CGFloat(sectionIndex - anchor.sectionIndex) * rowStride
            )
        )
    }
}

private struct BrowserSidebarTabDropFrameAnchor {
    let sectionIndex: Int
    let frame: CGRect
}

struct BrowserSidebarTabDragPreviewState: Equatable {
    let tabID: String
    let size: CGSize
    let pointerOffsetFromCenter: CGSize
    var location: CGPoint

    init(tabID: String, sourceFrame: CGRect, location: CGPoint) {
        self.tabID = tabID
        size = sourceFrame.size
        pointerOffsetFromCenter = CGSize(
            width: location.x - sourceFrame.midX,
            height: location.y - sourceFrame.midY
        )
        self.location = location
    }

    var center: CGPoint {
        CGPoint(
            x: location.x - pointerOffsetFromCenter.width,
            y: location.y - pointerOffsetFromCenter.height
        )
    }
}

struct BrowserSidebarTabDragTargetResolver {
    let verticalSnapDistance: CGFloat
    let horizontalTolerance: CGFloat

    func target(
        for location: CGPoint,
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        canMoveToTarget: (BrowserSidebarTabDropTarget) -> Bool
    ) -> BrowserSidebarTabDropTarget? {
        var bestCandidate: BrowserSidebarTabDropCandidate?

        func consider(_ candidate: BrowserSidebarTabDropCandidate?) {
            guard let candidate, canMoveToTarget(candidate.target) else {
                return
            }

            if let currentBest = bestCandidate {
                if candidate.isCloser(than: currentBest) {
                    bestCandidate = candidate
                }
            } else {
                bestCandidate = candidate
            }
        }

        for emptySectionFrame in emptySectionFrames {
            consider(
                makeCandidate(
                    target: emptySectionFrame.target,
                    location: location,
                    frame: emptySectionFrame.frame,
                    yPosition: emptySectionFrame.frame.midY
                )
            )
        }

        for rowFrame in rowFrames {
            consider(
                makeCandidate(
                    target: BrowserSidebarTabDropTarget(
                        section: rowFrame.section,
                        sectionIndex: rowFrame.sectionIndex
                    ),
                    location: location,
                    frame: rowFrame.frame,
                    yPosition: rowFrame.frame.minY
                )
            )
            consider(
                makeCandidate(
                    target: BrowserSidebarTabDropTarget(
                        section: rowFrame.section,
                        sectionIndex: rowFrame.sectionIndex + 1
                    ),
                    location: location,
                    frame: rowFrame.frame,
                    yPosition: rowFrame.frame.maxY
                )
            )
        }

        return bestCandidate?.target
    }

    private func makeCandidate(
        target: BrowserSidebarTabDropTarget,
        location: CGPoint,
        frame: CGRect,
        yPosition: CGFloat
    ) -> BrowserSidebarTabDropCandidate? {
        guard isHorizontallyReachable(location.x, in: frame) else {
            return nil
        }

        let verticalDistance = abs(location.y - yPosition)
        guard verticalDistance <= verticalSnapDistance else {
            return nil
        }

        return BrowserSidebarTabDropCandidate(
            target: target,
            verticalDistance: verticalDistance,
            sectionDistance: abs(location.y - frame.midY)
        )
    }

    private func isHorizontallyReachable(_ xLocation: CGFloat, in frame: CGRect) -> Bool {
        xLocation >= frame.minX - horizontalTolerance && xLocation <= frame.maxX + horizontalTolerance
    }
}

struct BrowserSidebarTabDropIndicatorFrameResolver {
    func frame(
        for target: BrowserSidebarTabDropTarget?,
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        horizontalInset: CGFloat,
        thickness: CGFloat
    ) -> CGRect? {
        guard let target else {
            return nil
        }

        let sectionRowFrames = rowFrames.filter { $0.section == target.section }

        if let previousRowFrame = sectionRowFrames.first(where: { $0.sectionIndex == target.sectionIndex - 1 }) {
            return indicatorFrame(
                alignedTo: previousRowFrame.frame,
                yPosition: previousRowFrame.frame.maxY,
                horizontalInset: horizontalInset,
                thickness: thickness
            )
        }

        if let targetRowFrame = sectionRowFrames.first(where: { $0.sectionIndex == target.sectionIndex }) {
            return indicatorFrame(
                alignedTo: targetRowFrame.frame,
                yPosition: targetRowFrame.frame.minY,
                horizontalInset: horizontalInset,
                thickness: thickness
            )
        }

        if
            target.sectionIndex == 0,
            let emptySectionFrame = emptySectionFrames.first(where: { $0.section == target.section })
        {
            return indicatorFrame(
                alignedTo: emptySectionFrame.frame,
                yPosition: emptySectionFrame.frame.midY,
                horizontalInset: horizontalInset,
                thickness: thickness
            )
        }

        return nil
    }

    private func indicatorFrame(
        alignedTo frame: CGRect,
        yPosition: CGFloat,
        horizontalInset: CGFloat,
        thickness: CGFloat
    ) -> CGRect {
        CGRect(
            x: frame.minX + horizontalInset,
            y: yPosition - thickness / 2,
            width: max(frame.width - horizontalInset * 2, 0),
            height: thickness
        )
    }
}

private struct BrowserSidebarTabDropCandidate {
    let target: BrowserSidebarTabDropTarget
    let verticalDistance: CGFloat
    let sectionDistance: CGFloat

    func isCloser(than other: BrowserSidebarTabDropCandidate) -> Bool {
        if verticalDistance == other.verticalDistance {
            return sectionDistance < other.sectionDistance
        }

        return verticalDistance < other.verticalDistance
    }
}
