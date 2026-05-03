import CoreGraphics

// MARK: - BrowserSidebarTabSection

enum BrowserSidebarTabSection: Equatable {
    case app
    case spacePinned
    case temporary

    // MARK: Internal

    var placement: BrowserTabPlacement {
        switch self {
        case .app:
            .app
        case .spacePinned:
            .spacePinned
        case .temporary:
            .temporary
        }
    }

    var sortPriority: Int {
        switch self {
        case .app:
            0
        case .spacePinned:
            1
        case .temporary:
            2
        }
    }
}

// MARK: - BrowserSidebarTabDropTarget

struct BrowserSidebarTabDropTarget: Equatable {
    // MARK: Lifecycle

    init(section: BrowserSidebarTabSection, sectionIndex: Int, spaceID: String? = nil) {
        self.section = section
        self.sectionIndex = sectionIndex
        self.spaceID = spaceID
    }

    // MARK: Internal

    let section: BrowserSidebarTabSection
    let sectionIndex: Int
    let spaceID: String?
}

// MARK: - BrowserSidebarTabRowFrame

struct BrowserSidebarTabRowFrame: Equatable {
    // MARK: Lifecycle

    init(
        tabID: String,
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String? = nil,
        frame: CGRect
    ) {
        self.tabID = tabID
        self.section = section
        self.sectionIndex = sectionIndex
        self.spaceID = spaceID
        self.frame = frame
    }

    // MARK: Internal

    let tabID: String
    let section: BrowserSidebarTabSection
    let sectionIndex: Int
    let spaceID: String?
    let frame: CGRect
}

// MARK: - BrowserSidebarAppTabFrame

struct BrowserSidebarAppTabFrame: Equatable {
    let tabID: String
    let sectionIndex: Int
    let frame: CGRect
}

// MARK: - BrowserSidebarEmptySectionFrame

struct BrowserSidebarEmptySectionFrame: Equatable {
    // MARK: Lifecycle

    init(section: BrowserSidebarTabSection, spaceID: String? = nil, frame: CGRect) {
        self.section = section
        self.spaceID = spaceID
        self.frame = frame
    }

    // MARK: Internal

    let section: BrowserSidebarTabSection
    let spaceID: String?
    let frame: CGRect

    var target: BrowserSidebarTabDropTarget {
        BrowserSidebarTabDropTarget(section: section, sectionIndex: 0, spaceID: spaceID)
    }
}

// MARK: - BrowserSidebarAppTabGridLayout

struct BrowserSidebarAppTabGridLayout: Equatable {
    // MARK: Internal

    static let maxColumns = 4
    static let maxRows = 2
    static let capacity = maxColumns * maxRows

    let spacing: CGFloat

    func frames(for count: Int, availableWidth: CGFloat) -> [CGRect] {
        let count = min(max(count, 0), Self.capacity)
        guard count > 0 else {
            return []
        }

        let availableWidth = max(availableWidth, 0)
        let baseTileSide = tileSide(availableWidth: availableWidth)
        var frames = [CGRect]()
        frames.reserveCapacity(count)

        var remainingCount = count
        var rowIndex = 0
        while remainingCount > 0, rowIndex < Self.maxRows {
            let rowItemCount = min(remainingCount, Self.maxColumns)
            let itemWidth = tileWidth(rowItemCount: rowItemCount, availableWidth: availableWidth)
            let y = CGFloat(rowIndex) * (baseTileSide + spacing)

            for columnIndex in 0..<rowItemCount {
                frames.append(
                    CGRect(
                        x: CGFloat(columnIndex) * (itemWidth + spacing),
                        y: y,
                        width: itemWidth,
                        height: baseTileSide
                    )
                )
            }

            remainingCount -= rowItemCount
            rowIndex += 1
        }

        return frames
    }

    func height(for count: Int, availableWidth: CGFloat) -> CGFloat {
        let rowCount = min((max(count, 0) + Self.maxColumns - 1) / Self.maxColumns, Self.maxRows)
        guard rowCount > 0 else {
            return 0
        }

        let baseTileSide = tileSide(availableWidth: availableWidth)
        return CGFloat(rowCount) * baseTileSide + CGFloat(rowCount - 1) * spacing
    }

    // MARK: Private

    private func tileSide(availableWidth: CGFloat) -> CGFloat {
        max((availableWidth - CGFloat(Self.maxColumns - 1) * spacing) / CGFloat(Self.maxColumns), 0)
    }

    private func tileWidth(rowItemCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard rowItemCount > 0 else {
            return 0
        }

        if rowItemCount == Self.maxColumns {
            return tileSide(availableWidth: availableWidth)
        }

        return max((availableWidth - CGFloat(rowItemCount - 1) * spacing) / CGFloat(rowItemCount), 0)
    }
}

// MARK: - BrowserSidebarTabFrameSynchronizer

enum BrowserSidebarTabFrameSynchronizer {
    // MARK: Internal

    static func synchronizedRowFrames(
        _ rowFrames: [String: BrowserSidebarTabRowFrame],
        spacePinnedTabIDs: [String],
        temporaryTabIDs: [String],
        spaceID: String? = nil
    ) -> [String: BrowserSidebarTabRowFrame] {
        let expectedLocations = expectedRowLocations(
            spacePinnedTabIDs: spacePinnedTabIDs,
            temporaryTabIDs: temporaryTabIDs,
            spaceID: spaceID
        )

        return rowFrames.reduce(into: [:]) { synchronizedRowFrames, item in
            let tabID = item.key
            let rowFrame = item.value

            guard
                rowFrame.tabID == tabID,
                let expectedLocation = expectedLocations[tabID],
                rowFrame.section == expectedLocation.section,
                rowFrame.sectionIndex == expectedLocation.sectionIndex,
                rowFrame.spaceID == expectedLocation.spaceID
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
        spacePinnedTabIDs: [String],
        temporaryTabIDs: [String],
        rowHeight: CGFloat,
        rowSpacing: CGFloat,
        spaceID: String? = nil
    ) -> [BrowserSidebarTabRowFrame] {
        let spacePinnedRowFrames = estimatedRowFrames(
            for: .spacePinned,
            tabIDs: spacePinnedTabIDs,
            spaceID: spaceID,
            rowFrames: rowFrames,
            fallbackRowFrames: fallbackRowFrames,
            emptySectionFrames: emptySectionFrames,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing
        )
        let temporaryRowFrames = estimatedRowFrames(
            for: .temporary,
            tabIDs: temporaryTabIDs,
            spaceID: spaceID,
            rowFrames: rowFrames,
            fallbackRowFrames: fallbackRowFrames,
            emptySectionFrames: emptySectionFrames,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing
        )

        return spacePinnedRowFrames + temporaryRowFrames
    }

    static func synchronizedEmptySectionFrames(
        _ emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        spacePinnedTabIDs: [String],
        temporaryTabIDs: [String],
        spaceID: String? = nil
    ) -> [BrowserSidebarEmptySectionFrame] {
        emptySectionFrames.filter { emptySectionFrame in
            guard emptySectionFrame.spaceID == spaceID else {
                return false
            }

            switch emptySectionFrame.section {
            case .app:
                return false
            case .spacePinned:
                return spacePinnedTabIDs.isEmpty
            case .temporary:
                return temporaryTabIDs.isEmpty
            }
        }
    }

    // MARK: Private

    private static func expectedRowLocations(
        spacePinnedTabIDs: [String],
        temporaryTabIDs: [String],
        spaceID: String?
    ) -> [String: BrowserSidebarTabDropTarget] {
        var locations = [String: BrowserSidebarTabDropTarget]()

        for (index, tabID) in spacePinnedTabIDs.enumerated() {
            locations[tabID] = BrowserSidebarTabDropTarget(section: .spacePinned, sectionIndex: index, spaceID: spaceID)
        }

        for (index, tabID) in temporaryTabIDs.enumerated() {
            locations[tabID] = BrowserSidebarTabDropTarget(section: .temporary, sectionIndex: index, spaceID: spaceID)
        }

        return locations
    }

    private static func estimatedRowFrames(
        for section: BrowserSidebarTabSection,
        tabIDs: [String],
        spaceID: String?,
        rowFrames: [String: BrowserSidebarTabRowFrame],
        fallbackRowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        rowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> [BrowserSidebarTabRowFrame] {
        guard !tabIDs.isEmpty else {
            return []
        }

        let anchors = tabIDs.enumerated().compactMap { index, tabID -> BrowserSidebarTabDropFrameAnchor? in
            guard
                let rowFrame = synchronizedDropRowFrame(
                    for: tabID,
                    section: section,
                    sectionIndex: index,
                    spaceID: spaceID,
                    rowFrames: rowFrames,
                    fallbackRowFrames: fallbackRowFrames
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
                    spaceID: spaceID,
                    anchor: anchor,
                    rowSpacing: rowSpacing
                )
            }
        }

        let candidateRowFrames = tabIDs.flatMap { tabID in
            [rowFrames[tabID]].compactMap(\.self) + fallbackRowFrames.filter {
                $0.tabID == tabID && $0.spaceID == spaceID
            }
        }
        if let firstSectionFrame = candidateRowFrames
            .filter({ $0.section == section && $0.spaceID == spaceID })
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
                    spaceID: spaceID,
                    anchor: anchor,
                    rowSpacing: rowSpacing
                )
            }
        }

        if let emptySectionFrame = emptySectionFrames.first(where: {
            $0.section == section && $0.spaceID == spaceID
        })?.frame {
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
                    spaceID: spaceID,
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
        spaceID: String?,
        rowFrames: [String: BrowserSidebarTabRowFrame],
        fallbackRowFrames: [BrowserSidebarTabRowFrame]
    ) -> BrowserSidebarTabRowFrame? {
        if let rowFrame = rowFrames[tabID],
           rowFrame.section == section,
           rowFrame.sectionIndex == sectionIndex,
           rowFrame.spaceID == spaceID
        {
            return rowFrame
        }

        return fallbackRowFrames
            .first {
                $0.tabID == tabID
                    && $0.section == section
                    && $0.sectionIndex == sectionIndex
                    && $0.spaceID == spaceID
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
        spaceID: String?,
        anchor: BrowserSidebarTabDropFrameAnchor,
        rowSpacing: CGFloat
    ) -> BrowserSidebarTabRowFrame {
        let rowStride = anchor.frame.height + rowSpacing
        return BrowserSidebarTabRowFrame(
            tabID: tabID,
            section: section,
            sectionIndex: sectionIndex,
            spaceID: spaceID,
            frame: anchor.frame.offsetBy(
                dx: 0,
                dy: CGFloat(sectionIndex - anchor.sectionIndex) * rowStride
            )
        )
    }
}

// MARK: - BrowserSidebarTabDropFrameAnchor

private struct BrowserSidebarTabDropFrameAnchor {
    let sectionIndex: Int
    let frame: CGRect
}

// MARK: - BrowserSidebarAppTabFrameSynchronizer

enum BrowserSidebarAppTabFrameSynchronizer {
    static func synchronizedFrames(
        _ appTabFrames: [String: BrowserSidebarAppTabFrame],
        appTabIDs: [String]
    ) -> [String: BrowserSidebarAppTabFrame] {
        let expectedLocations: [String: Int] = appTabIDs.enumerated().reduce(into: [:]) { locations, item in
            let (index, tabID) = item
            locations[tabID] = locations[tabID] ?? index
        }

        return appTabFrames.reduce(into: [:]) { synchronizedFrames, item in
            let tabID = item.key
            let frame = item.value

            guard
                frame.tabID == tabID,
                frame.sectionIndex == expectedLocations[tabID]
            else {
                return
            }

            synchronizedFrames[tabID] = frame
        }
    }

    static func sortedFrameList(_ appTabFrames: [String: BrowserSidebarAppTabFrame]) -> [BrowserSidebarAppTabFrame] {
        appTabFrames.values.sorted { $0.sectionIndex < $1.sectionIndex }
    }

    static func dropFrameList(
        containerFrame: CGRect?,
        appTabIDs: [String],
        spacing: CGFloat
    ) -> [BrowserSidebarAppTabFrame] {
        guard let containerFrame, !appTabIDs.isEmpty else {
            return []
        }

        let layout = BrowserSidebarAppTabGridLayout(spacing: spacing)
        return zip(
            appTabIDs,
            layout.frames(for: appTabIDs.count, availableWidth: containerFrame.width)
        )
        .enumerated()
        .map { index, item in
            let (tabID, frame) = item
            return BrowserSidebarAppTabFrame(
                tabID: tabID,
                sectionIndex: index,
                frame: frame.offsetBy(dx: containerFrame.minX, dy: containerFrame.minY)
            )
        }
    }
}

// MARK: - BrowserSidebarTabDragPreviewState

struct BrowserSidebarTabDragPreviewState: Equatable {
    // MARK: Lifecycle

    init(tabID: String, sourceFrame: CGRect, location: CGPoint) {
        self.tabID = tabID
        self.size = sourceFrame.size
        self.pointerOffsetFromCenterUnit = CGSize(
            width: sourceFrame.width > 0 ? (location.x - sourceFrame.midX) / sourceFrame.width : 0,
            height: sourceFrame.height > 0 ? (location.y - sourceFrame.midY) / sourceFrame.height : 0
        )
        self.location = location
    }

    // MARK: Internal

    let tabID: String
    var size: CGSize
    var location: CGPoint

    var center: CGPoint {
        CGPoint(
            x: location.x - pointerOffsetFromCenterUnit.width * size.width,
            y: location.y - pointerOffsetFromCenterUnit.height * size.height
        )
    }

    mutating func update(location: CGPoint, size: CGSize) {
        self.location = location
        self.size = size
    }

    // MARK: Private

    private let pointerOffsetFromCenterUnit: CGSize
}

// MARK: - BrowserSidebarTabDragTargetResolver

struct BrowserSidebarTabDragTargetResolver {
    // MARK: Internal

    let verticalSnapDistance: CGFloat
    let horizontalTolerance: CGFloat

    func target(
        for location: CGPoint,
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        appTabFrames: [BrowserSidebarAppTabFrame] = [],
        appTabContainerFrame: CGRect? = nil,
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

        for appTabFrame in appTabFrames {
            consider(makeAppTabCandidate(for: appTabFrame, location: location))
        }

        if let appTabContainerFrame, appTabFrames.isEmpty {
            consider(
                makeCandidate(
                    target: BrowserSidebarTabDropTarget(section: .app, sectionIndex: 0),
                    location: location,
                    frame: appTabContainerFrame,
                    yPosition: appTabContainerFrame.midY
                )
            )
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
                        sectionIndex: rowFrame.sectionIndex,
                        spaceID: rowFrame.spaceID
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
                        sectionIndex: rowFrame.sectionIndex + 1,
                        spaceID: rowFrame.spaceID
                    ),
                    location: location,
                    frame: rowFrame.frame,
                    yPosition: rowFrame.frame.maxY
                )
            )
        }

        return bestCandidate?.target
    }

    // MARK: Private

    private func makeAppTabCandidate(
        for appTabFrame: BrowserSidebarAppTabFrame,
        location: CGPoint
    ) -> BrowserSidebarTabDropCandidate? {
        let frame = appTabFrame.frame
        guard isReachable(location, in: frame) else {
            return nil
        }

        let sectionIndex = location.x < frame.midX ? appTabFrame.sectionIndex : appTabFrame.sectionIndex + 1
        let distance = distanceFrom(location, to: frame)
        return BrowserSidebarTabDropCandidate(
            target: BrowserSidebarTabDropTarget(section: .app, sectionIndex: sectionIndex),
            verticalDistance: distance,
            sectionDistance: distance
        )
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

    private func isReachable(_ location: CGPoint, in frame: CGRect) -> Bool {
        frame.insetBy(dx: -horizontalTolerance, dy: -verticalSnapDistance).contains(location)
    }

    private func distanceFrom(_ location: CGPoint, to frame: CGRect) -> CGFloat {
        let dx =
            if location.x < frame.minX {
                frame.minX - location.x
            } else if location.x > frame.maxX {
                location.x - frame.maxX
            } else {
                CGFloat(0)
            }

        let dy =
            if location.y < frame.minY {
                frame.minY - location.y
            } else if location.y > frame.maxY {
                location.y - frame.maxY
            } else {
                CGFloat(0)
            }

        return hypot(dx, dy)
    }
}

// MARK: - BrowserSidebarTabDropIndicatorFrameResolver

struct BrowserSidebarTabDropIndicatorFrameResolver {
    // MARK: Internal

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

        guard target.section != .app else {
            return nil
        }

        let sectionRowFrames = rowFrames.filter {
            $0.section == target.section && $0.spaceID == target.spaceID
        }

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
            let emptySectionFrame = emptySectionFrames.first(where: {
                $0.section == target.section && $0.spaceID == target.spaceID
            })
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

    // MARK: Private

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

// MARK: - BrowserSidebarTabDropCandidate

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
