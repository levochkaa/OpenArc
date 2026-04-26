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

enum BrowserSidebarTabDropIndicatorEdge: Equatable {
    case top
    case bottom
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

struct BrowserSidebarTabDropIndicatorResolver {
    func edge(
        for section: BrowserSidebarTabSection,
        sectionIndex: Int,
        target: BrowserSidebarTabDropTarget?
    ) -> BrowserSidebarTabDropIndicatorEdge? {
        guard target?.section == section else {
            return nil
        }

        if target?.sectionIndex == 0, sectionIndex == 0 {
            return .top
        }

        if target?.sectionIndex == sectionIndex + 1 {
            return .bottom
        }

        return nil
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
