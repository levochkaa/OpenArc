import CoreGraphics

// MARK: - BrowserSidebarTabSection

enum BrowserSidebarTabSection: Hashable {
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

struct BrowserSidebarTabDropTarget: Hashable {
    // MARK: Lifecycle

    init(
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String? = nil,
        pinnedFolderID: String? = nil
    ) {
        self.section = section
        self.sectionIndex = sectionIndex
        self.spaceID = spaceID
        self.pinnedFolderID = pinnedFolderID
    }

    // MARK: Internal

    let section: BrowserSidebarTabSection
    let sectionIndex: Int
    let spaceID: String?
    let pinnedFolderID: String?
}

// MARK: - BrowserSidebarTabRowFrame

struct BrowserSidebarTabRowFrame: Equatable {
    // MARK: Lifecycle

    init(
        tabID: String,
        section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String? = nil,
        pinnedFolderID: String? = nil,
        folderChildIndex: Int? = nil,
        frame: CGRect
    ) {
        self.tabID = tabID
        self.section = section
        self.sectionIndex = sectionIndex
        self.spaceID = spaceID
        self.pinnedFolderID = pinnedFolderID
        self.folderChildIndex = folderChildIndex
        self.frame = frame
    }

    // MARK: Internal

    let tabID: String
    let section: BrowserSidebarTabSection
    let sectionIndex: Int
    let spaceID: String?
    let pinnedFolderID: String?
    let folderChildIndex: Int?
    let frame: CGRect
}

// MARK: - BrowserSidebarPinnedFolderRowFrame

struct BrowserSidebarPinnedFolderRowFrame: Equatable {
    // MARK: Lifecycle

    init(
        folderID: String,
        firstSectionIndex: Int,
        afterSectionIndex: Int,
        childCount: Int,
        spaceID: String?,
        frame: CGRect,
        childPreviewFrame: CGRect? = nil
    ) {
        self.folderID = folderID
        self.firstSectionIndex = firstSectionIndex
        self.afterSectionIndex = afterSectionIndex
        self.childCount = childCount
        self.spaceID = spaceID
        self.frame = frame
        self.childPreviewFrame = childPreviewFrame ?? frame
    }

    // MARK: Internal

    let folderID: String
    let firstSectionIndex: Int
    let afterSectionIndex: Int
    let childCount: Int
    let spaceID: String?
    let frame: CGRect
    let childPreviewFrame: CGRect
}

// MARK: - BrowserSidebarSpaceHeaderFrame

struct BrowserSidebarSpaceHeaderFrame: Equatable {
    let spaceID: String
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

// MARK: - BrowserSidebarTabDropProposal

struct BrowserSidebarTabDropProposal: Equatable {
    let target: BrowserSidebarTabDropTarget
    let indicatorFrame: CGRect?
    let previewFrame: CGRect?
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
        spaceID: String? = nil,
        spacePinnedSectionIndices: [String: Int] = [:]
    ) -> [String: BrowserSidebarTabRowFrame] {
        let expectedLocations = expectedRowLocations(
            spacePinnedTabIDs: spacePinnedTabIDs,
            temporaryTabIDs: temporaryTabIDs,
            spaceID: spaceID,
            spacePinnedSectionIndices: spacePinnedSectionIndices
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
        spaceID: String? = nil,
        spacePinnedSectionIndices: [String: Int] = [:]
    ) -> [BrowserSidebarTabRowFrame] {
        let spacePinnedRowFrames = estimatedRowFrames(
            for: .spacePinned,
            tabIDs: spacePinnedTabIDs,
            spaceID: spaceID,
            sectionIndices: spacePinnedSectionIndices,
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
            sectionIndices: [:],
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
        spaceID: String?,
        spacePinnedSectionIndices: [String: Int]
    ) -> [String: BrowserSidebarTabDropTarget] {
        var locations = [String: BrowserSidebarTabDropTarget]()

        for (index, tabID) in spacePinnedTabIDs.enumerated() {
            locations[tabID] = BrowserSidebarTabDropTarget(
                section: .spacePinned,
                sectionIndex: spacePinnedSectionIndices[tabID] ?? index,
                spaceID: spaceID
            )
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
        sectionIndices: [String: Int],
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
            let sectionIndex = sectionIndices[tabID] ?? index
            guard
                let rowFrame = synchronizedDropRowFrame(
                    for: tabID,
                    section: section,
                    sectionIndex: sectionIndex,
                    spaceID: spaceID,
                    rowFrames: rowFrames,
                    fallbackRowFrames: fallbackRowFrames
                ),
                rowFrame.section == section,
                rowFrame.sectionIndex == sectionIndex
            else {
                return nil
            }

            return BrowserSidebarTabDropFrameAnchor(sectionIndex: sectionIndex, frame: rowFrame.frame)
        }

        if !anchors.isEmpty {
            return tabIDs.enumerated().map { index, tabID in
                let sectionIndex = sectionIndices[tabID] ?? index
                let anchor = nearestAnchor(to: sectionIndex, anchors: anchors)
                return rowFrame(
                    tabID: tabID,
                    section: section,
                    sectionIndex: sectionIndex,
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
                let sectionIndex = sectionIndices[tabID] ?? index
                return rowFrame(
                    tabID: tabID,
                    section: section,
                    sectionIndex: sectionIndex,
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
                let sectionIndex = sectionIndices[tabID] ?? index
                return rowFrame(
                    tabID: tabID,
                    section: section,
                    sectionIndex: sectionIndex,
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
        self.pointerOffsetFromCenter = CGSize(
            width: location.x - sourceFrame.midX,
            height: location.y - sourceFrame.midY
        )
        self.location = location
    }

    // MARK: Internal

    let tabID: String
    var size: CGSize
    var location: CGPoint

    var center: CGPoint {
        CGPoint(
            x: location.x - pointerOffsetFromCenter.width,
            y: location.y - pointerOffsetFromCenter.height
        )
    }

    mutating func update(location: CGPoint, size: CGSize) {
        self.location = location
        self.size = size
    }

    // MARK: Private

    private let pointerOffsetFromCenter: CGSize
}

// MARK: - BrowserSidebarTabDragSession

struct BrowserSidebarTabDragSession: Equatable {
    // MARK: Lifecycle

    init(layout: BrowserSidebarTabDropLayout, hysteresisDistance: CGFloat) {
        self.layout = layout
        self.hysteresisDistance = hysteresisDistance
    }

    // MARK: Internal

    let layout: BrowserSidebarTabDropLayout
    let hysteresisDistance: CGFloat
    private(set) var lastProposal: BrowserSidebarTabDropProposal?

    mutating func proposal(
        for location: CGPoint,
        canMoveToTarget: (BrowserSidebarTabDropTarget) -> Bool
    ) -> BrowserSidebarTabDropProposal? {
        let proposal = layout.proposal(
            for: location,
            previousTarget: lastProposal?.target,
            hysteresisDistance: hysteresisDistance,
            canMoveToTarget: canMoveToTarget
        )
        lastProposal = proposal
        return proposal
    }
}

// MARK: - BrowserSidebarTabDropLayout

struct BrowserSidebarTabDropLayout: Equatable {
    // MARK: Lifecycle

    init(
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame] = [],
        spaceHeaderFrames: [BrowserSidebarSpaceHeaderFrame] = [],
        appTabFrames: [BrowserSidebarAppTabFrame] = [],
        appTabContainerFrame: CGRect? = nil,
        horizontalInset: CGFloat,
        thickness: CGFloat,
        verticalSnapDistance: CGFloat,
        horizontalTolerance: CGFloat
    ) {
        self.verticalSnapDistance = verticalSnapDistance
        self.horizontalTolerance = horizontalTolerance
        self.slots = Self.makeSlots(
            rowFrames: rowFrames,
            emptySectionFrames: emptySectionFrames,
            pinnedFolderFrames: pinnedFolderFrames,
            spaceHeaderFrames: spaceHeaderFrames,
            appTabFrames: appTabFrames,
            appTabContainerFrame: appTabContainerFrame,
            horizontalInset: horizontalInset,
            thickness: thickness,
            verticalSnapDistance: verticalSnapDistance
        )
    }

    // MARK: Internal

    let verticalSnapDistance: CGFloat
    let horizontalTolerance: CGFloat
    let slots: [BrowserSidebarTabDropSlot]

    func proposal(
        for location: CGPoint,
        previousTarget: BrowserSidebarTabDropTarget? = nil,
        hysteresisDistance: CGFloat = 0,
        canMoveToTarget: (BrowserSidebarTabDropTarget) -> Bool
    ) -> BrowserSidebarTabDropProposal? {
        let eligibleSlots = slots.filter { canMoveToTarget($0.target) }
        guard !eligibleSlots.isEmpty else {
            return nil
        }

        if let previousTarget {
            let previousSlots = eligibleSlots.filter { $0.target == previousTarget }
            if let previousSlot = previousSlots.first(where: {
                $0.contains(
                    location,
                    horizontalTolerance: horizontalTolerance,
                    verticalExpansion: hysteresisDistance
                )
            }) {
                return previousSlot.proposal
            }
        }

        let candidates = eligibleSlots.compactMap { slot -> BrowserSidebarTabDropCandidate? in
            if slot.contains(location, horizontalTolerance: horizontalTolerance, verticalExpansion: 0) {
                return BrowserSidebarTabDropCandidate(
                    slot: slot,
                    distance: slot.focusDistance(from: location),
                    containsLocation: true
                )
            }

            let distance = slot.distance(from: location, horizontalTolerance: horizontalTolerance)
            guard distance <= verticalSnapDistance else {
                return nil
            }

            return BrowserSidebarTabDropCandidate(
                slot: slot,
                distance: distance + slot.focusDistance(from: location) * 0.001,
                containsLocation: false
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.containsLocation != rhs.containsLocation {
                return lhs.containsLocation
            }

            if abs(lhs.distance - rhs.distance) > Self.distanceEpsilon {
                return lhs.distance < rhs.distance
            }

            return lhs.slot.priority < rhs.slot.priority
        }?.slot
            .proposal
    }

    // MARK: Private

    private static let distanceEpsilon: CGFloat = 0.5

    private static func makeSlots(
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame],
        spaceHeaderFrames: [BrowserSidebarSpaceHeaderFrame],
        appTabFrames: [BrowserSidebarAppTabFrame],
        appTabContainerFrame: CGRect?,
        horizontalInset: CGFloat,
        thickness: CGFloat,
        verticalSnapDistance: CGFloat
    ) -> [BrowserSidebarTabDropSlot] {
        var slots = [BrowserSidebarTabDropSlot]()
        slots.append(contentsOf: makeAppTabSlots(
            appTabFrames: appTabFrames,
            appTabContainerFrame: appTabContainerFrame,
            verticalSnapDistance: verticalSnapDistance
        ))
        slots.append(contentsOf: makeEmptySectionSlots(
            emptySectionFrames: emptySectionFrames,
            horizontalInset: horizontalInset,
            thickness: thickness,
            verticalSnapDistance: verticalSnapDistance
        ))
        slots.append(contentsOf: makeSpaceHeaderSlots(
            spaceHeaderFrames: spaceHeaderFrames,
            verticalSnapDistance: verticalSnapDistance
        ))
        slots.append(contentsOf: makePinnedFolderSlots(
            pinnedFolderFrames: pinnedFolderFrames,
            horizontalInset: horizontalInset,
            thickness: thickness,
            verticalSnapDistance: verticalSnapDistance
        ))
        slots.append(contentsOf: makeRowSlots(
            rowFrames: rowFrames,
            pinnedFolderFrames: pinnedFolderFrames,
            horizontalInset: horizontalInset,
            thickness: thickness,
            verticalSnapDistance: verticalSnapDistance
        ))
        return slots
    }

    private static func makeAppTabSlots(
        appTabFrames: [BrowserSidebarAppTabFrame],
        appTabContainerFrame: CGRect?,
        verticalSnapDistance: CGFloat
    ) -> [BrowserSidebarTabDropSlot] {
        let sortedFrames = appTabFrames.sorted { lhs, rhs in
            lhs.sectionIndex < rhs.sectionIndex
        }

        guard !sortedFrames.isEmpty else {
            guard let appTabContainerFrame, appTabContainerFrame.width > 0 else {
                return []
            }

            return [
                BrowserSidebarTabDropSlot(
                    target: BrowserSidebarTabDropTarget(section: .app, sectionIndex: 0),
                    hitFrame: appTabContainerFrame.insetBy(dx: 0, dy: -verticalSnapDistance),
                    indicatorFrame: nil,
                    previewFrame: appTabContainerFrame,
                    focusPoint: CGPoint(x: appTabContainerFrame.midX, y: appTabContainerFrame.midY),
                    priority: 0
                ),
            ]
        }

        return sortedFrames.flatMap { appTabFrame -> [BrowserSidebarTabDropSlot] in
            let frame = appTabFrame.frame
            guard frame.width > 0, frame.height > 0 else {
                return []
            }

            let leftFrame = CGRect(
                x: frame.minX,
                y: frame.minY - verticalSnapDistance,
                width: frame.width / 2,
                height: frame.height + verticalSnapDistance * 2
            )
            let rightFrame = CGRect(
                x: frame.midX,
                y: frame.minY - verticalSnapDistance,
                width: frame.width / 2,
                height: frame.height + verticalSnapDistance * 2
            )

            return [
                BrowserSidebarTabDropSlot(
                    target: BrowserSidebarTabDropTarget(section: .app, sectionIndex: appTabFrame.sectionIndex),
                    hitFrame: leftFrame,
                    indicatorFrame: nil,
                    previewFrame: frame,
                    focusPoint: CGPoint(x: leftFrame.midX, y: frame.midY),
                    priority: 0
                ),
                BrowserSidebarTabDropSlot(
                    target: BrowserSidebarTabDropTarget(section: .app, sectionIndex: appTabFrame.sectionIndex + 1),
                    hitFrame: rightFrame,
                    indicatorFrame: nil,
                    previewFrame: frame,
                    focusPoint: CGPoint(x: rightFrame.midX, y: frame.midY),
                    priority: 0
                ),
            ]
        }
    }

    private static func makeEmptySectionSlots(
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        horizontalInset: CGFloat,
        thickness: CGFloat,
        verticalSnapDistance: CGFloat
    ) -> [BrowserSidebarTabDropSlot] {
        emptySectionFrames.compactMap { emptySectionFrame in
            let frame = emptySectionFrame.frame
            guard frame.width > 0 else {
                return nil
            }

            let indicatorFrame = emptySectionFrame.section == .app
                ? nil
                : Self.indicatorFrame(
                    alignedTo: frame,
                    yPosition: frame.midY,
                    horizontalInset: horizontalInset,
                    thickness: thickness
                )

            return BrowserSidebarTabDropSlot(
                target: emptySectionFrame.target,
                hitFrame: frame.insetBy(dx: 0, dy: -verticalSnapDistance),
                indicatorFrame: indicatorFrame,
                previewFrame: frame,
                focusPoint: CGPoint(x: frame.midX, y: frame.midY),
                priority: 3
            )
        }
    }

    private static func makeSpaceHeaderSlots(
        spaceHeaderFrames: [BrowserSidebarSpaceHeaderFrame],
        verticalSnapDistance: CGFloat
    ) -> [BrowserSidebarTabDropSlot] {
        spaceHeaderFrames.compactMap { spaceHeaderFrame in
            let frame = spaceHeaderFrame.frame
            guard frame.width > 0, frame.height > 0 else {
                return nil
            }

            return BrowserSidebarTabDropSlot(
                target: BrowserSidebarTabDropTarget(
                    section: .spacePinned,
                    sectionIndex: 0,
                    spaceID: spaceHeaderFrame.spaceID
                ),
                hitFrame: frame.insetBy(dx: 0, dy: -verticalSnapDistance * 0.25),
                indicatorFrame: nil,
                previewFrame: frame,
                focusPoint: CGPoint(x: frame.midX, y: frame.midY),
                priority: 1
            )
        }
    }

    private static func makePinnedFolderSlots(
        pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame],
        horizontalInset: CGFloat,
        thickness: CGFloat,
        verticalSnapDistance: CGFloat
    ) -> [BrowserSidebarTabDropSlot] {
        pinnedFolderFrames.flatMap { folderFrame -> [BrowserSidebarTabDropSlot] in
            let frame = folderFrame.frame
            guard frame.width > 0, frame.height > 0 else {
                return []
            }

            let edgeHeight = max(frame.height * 0.3, 1)
            let beforeTarget = BrowserSidebarTabDropTarget(
                section: .spacePinned,
                sectionIndex: folderFrame.firstSectionIndex,
                spaceID: folderFrame.spaceID
            )
            let afterTarget = BrowserSidebarTabDropTarget(
                section: .spacePinned,
                sectionIndex: folderFrame.afterSectionIndex,
                spaceID: folderFrame.spaceID
            )
            let folderTarget = BrowserSidebarTabDropTarget(
                section: .spacePinned,
                sectionIndex: 0,
                spaceID: folderFrame.spaceID,
                pinnedFolderID: folderFrame.folderID
            )

            return [
                BrowserSidebarTabDropSlot(
                    target: beforeTarget,
                    hitFrame: CGRect(
                        x: frame.minX,
                        y: frame.minY - verticalSnapDistance,
                        width: frame.width,
                        height: edgeHeight + verticalSnapDistance
                    ),
                    indicatorFrame: Self.indicatorFrame(
                        alignedTo: frame,
                        yPosition: frame.minY,
                        horizontalInset: horizontalInset,
                        thickness: thickness
                    ),
                    previewFrame: frame,
                    focusPoint: CGPoint(x: frame.midX, y: frame.minY),
                    priority: 1
                ),
                BrowserSidebarTabDropSlot(
                    target: folderTarget,
                    hitFrame: CGRect(
                        x: frame.minX,
                        y: frame.minY + edgeHeight,
                        width: frame.width,
                        height: max(frame.height - edgeHeight, 1)
                    ),
                    indicatorFrame: nil,
                    previewFrame: folderFrame.childPreviewFrame,
                    focusPoint: CGPoint(x: frame.midX, y: frame.midY),
                    priority: 0
                ),
                BrowserSidebarTabDropSlot(
                    target: afterTarget,
                    hitFrame: CGRect(
                        x: frame.minX,
                        y: frame.maxY,
                        width: frame.width,
                        height: verticalSnapDistance
                    ),
                    indicatorFrame: Self.indicatorFrame(
                        alignedTo: frame,
                        yPosition: frame.maxY,
                        horizontalInset: horizontalInset,
                        thickness: thickness
                    ),
                    previewFrame: frame,
                    focusPoint: CGPoint(x: frame.midX, y: frame.maxY),
                    priority: 1
                ),
            ]
        }
    }

    private static func makeRowSlots(
        rowFrames: [BrowserSidebarTabRowFrame],
        pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame],
        horizontalInset: CGFloat,
        thickness: CGFloat,
        verticalSnapDistance: CGFloat
    ) -> [BrowserSidebarTabDropSlot] {
        let groupedRows = Dictionary(grouping: rowFrames.filter {
            $0.frame.width > 0 && $0.frame.height > 0
        }) { rowFrame in
            BrowserSidebarTabDropSectionKey(
                section: rowFrame.section,
                spaceID: rowFrame.spaceID,
                pinnedFolderID: rowFrame.pinnedFolderID
            )
        }

        return groupedRows.values.flatMap { rows -> [BrowserSidebarTabDropSlot] in
            let sortedRows = rows.sorted { lhs, rhs in
                let lhsIndex = lhs.folderChildIndex ?? lhs.sectionIndex
                let rhsIndex = rhs.folderChildIndex ?? rhs.sectionIndex
                if lhsIndex == rhsIndex {
                    return lhs.frame.minY < rhs.frame.minY
                }

                return lhsIndex < rhsIndex
            }
            guard let firstRow = sortedRows.first else {
                return []
            }
            let parentFolderFrame = firstRow.pinnedFolderID.flatMap { pinnedFolderID in
                pinnedFolderFrames.first {
                    $0.folderID == pinnedFolderID && $0.spaceID == firstRow.spaceID
                }?.frame
            }
            let parentFolderPreviewFrame = firstRow.pinnedFolderID.flatMap { pinnedFolderID in
                pinnedFolderFrames.first {
                    $0.folderID == pinnedFolderID && $0.spaceID == firstRow.spaceID
                }?.childPreviewFrame
            }

            return (0...sortedRows.count).map { insertionOffset in
                rowSlot(
                    insertionOffset: insertionOffset,
                    rows: sortedRows,
                    fallbackRow: firstRow,
                    parentFolderFrame: parentFolderFrame,
                    parentFolderPreviewFrame: parentFolderPreviewFrame,
                    horizontalInset: horizontalInset,
                    thickness: thickness,
                    verticalSnapDistance: verticalSnapDistance
                )
            }
        }
    }

    private static func rowSlot(
        insertionOffset: Int,
        rows: [BrowserSidebarTabRowFrame],
        fallbackRow: BrowserSidebarTabRowFrame,
        parentFolderFrame: CGRect?,
        parentFolderPreviewFrame: CGRect?,
        horizontalInset: CGFloat,
        thickness: CGFloat,
        verticalSnapDistance: CGFloat
    ) -> BrowserSidebarTabDropSlot {
        let previousRow = insertionOffset > 0 ? rows[insertionOffset - 1] : nil
        let nextRow = insertionOffset < rows.count ? rows[insertionOffset] : nil
        let referenceRow = nextRow ?? previousRow ?? fallbackRow
        let targetIndex =
            if let nextRow {
                nextRow.folderChildIndex ?? nextRow.sectionIndex
            } else if let previousRow {
                (previousRow.folderChildIndex ?? previousRow.sectionIndex) + 1
            } else {
                0
            }
        let lowerY =
            if let previousRow {
                previousRow.frame.midY
            } else {
                referenceRow.frame.minY - verticalSnapDistance
            }
        let upperY =
            if let nextRow {
                nextRow.frame.midY
            } else {
                referenceRow.frame.maxY + verticalSnapDistance
            }
        let yPosition =
            if let previousRow {
                previousRow.frame.maxY
            } else {
                referenceRow.frame.minY
            }
        let target = BrowserSidebarTabDropTarget(
            section: referenceRow.section,
            sectionIndex: targetIndex,
            spaceID: referenceRow.spaceID,
            pinnedFolderID: referenceRow.pinnedFolderID
        )
        let usesParentFolderHighlight = insertionOffset == 0
            && referenceRow.pinnedFolderID != nil
            && parentFolderFrame != nil
        let focusPoint = CGPoint(
            x: usesParentFolderHighlight
                ? (parentFolderFrame?.midX ?? referenceRow.frame.midX)
                : referenceRow.frame.midX,
            y: yPosition
        )

        return BrowserSidebarTabDropSlot(
            target: target,
            hitFrame: CGRect(
                x: referenceRow.frame.minX,
                y: min(lowerY, upperY),
                width: referenceRow.frame.width,
                height: max(abs(upperY - lowerY), 1)
            ),
            indicatorFrame: usesParentFolderHighlight
                ? nil
                : Self.indicatorFrame(
                    alignedTo: referenceRow.frame,
                    yPosition: yPosition,
                    horizontalInset: horizontalInset,
                    thickness: thickness
                ),
            previewFrame: usesParentFolderHighlight
                ? (parentFolderPreviewFrame ?? parentFolderFrame)
                : Optional(referenceRow.frame),
            focusPoint: focusPoint,
            priority: 2
        )
    }

    private static func indicatorFrame(
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

// MARK: - BrowserSidebarTabDragTargetResolver

struct BrowserSidebarTabDragTargetResolver {
    let verticalSnapDistance: CGFloat
    let horizontalTolerance: CGFloat

    func target(
        for location: CGPoint,
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame] = [],
        appTabFrames: [BrowserSidebarAppTabFrame] = [],
        appTabContainerFrame: CGRect? = nil,
        canMoveToTarget: (BrowserSidebarTabDropTarget) -> Bool
    ) -> BrowserSidebarTabDropTarget? {
        BrowserSidebarTabDropLayout(
            rowFrames: rowFrames,
            emptySectionFrames: emptySectionFrames,
            pinnedFolderFrames: pinnedFolderFrames,
            appTabFrames: appTabFrames,
            appTabContainerFrame: appTabContainerFrame,
            horizontalInset: 0,
            thickness: 0,
            verticalSnapDistance: verticalSnapDistance,
            horizontalTolerance: horizontalTolerance
        )
        .proposal(for: location, canMoveToTarget: canMoveToTarget)?
        .target
    }
}

// MARK: - BrowserSidebarTabDropSlot

struct BrowserSidebarTabDropSlot: Equatable {
    let target: BrowserSidebarTabDropTarget
    let hitFrame: CGRect
    let indicatorFrame: CGRect?
    let previewFrame: CGRect?
    let focusPoint: CGPoint
    let priority: Int

    var proposal: BrowserSidebarTabDropProposal {
        BrowserSidebarTabDropProposal(
            target: target,
            indicatorFrame: indicatorFrame,
            previewFrame: previewFrame
        )
    }

    func contains(
        _ location: CGPoint,
        horizontalTolerance: CGFloat,
        verticalExpansion: CGFloat
    ) -> Bool {
        hitFrame
            .insetBy(dx: -horizontalTolerance, dy: -verticalExpansion)
            .contains(location)
    }

    func distance(from location: CGPoint, horizontalTolerance: CGFloat) -> CGFloat {
        let reachableFrame = hitFrame.insetBy(dx: -horizontalTolerance, dy: 0)
        let dx =
            if location.x < reachableFrame.minX {
                reachableFrame.minX - location.x
            } else if location.x > reachableFrame.maxX {
                location.x - reachableFrame.maxX
            } else {
                CGFloat(0)
            }
        let dy =
            if location.y < reachableFrame.minY {
                reachableFrame.minY - location.y
            } else if location.y > reachableFrame.maxY {
                location.y - reachableFrame.maxY
            } else {
                CGFloat(0)
            }
        return hypot(dx, dy)
    }

    func focusDistance(from location: CGPoint) -> CGFloat {
        guard target.section == .app else {
            return abs(location.y - focusPoint.y)
        }

        return hypot(location.x - focusPoint.x, location.y - focusPoint.y)
    }
}

// MARK: - BrowserSidebarTabDropSectionKey

private struct BrowserSidebarTabDropSectionKey: Hashable {
    let section: BrowserSidebarTabSection
    let spaceID: String?
    let pinnedFolderID: String?
}

// MARK: - BrowserSidebarTabDropIndicatorFrameResolver

struct BrowserSidebarTabDropIndicatorFrameResolver {
    // MARK: Internal

    func frame(
        for target: BrowserSidebarTabDropTarget?,
        rowFrames: [BrowserSidebarTabRowFrame],
        emptySectionFrames: [BrowserSidebarEmptySectionFrame],
        pinnedFolderFrames: [BrowserSidebarPinnedFolderRowFrame] = [],
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
            $0.section == target.section
                && $0.spaceID == target.spaceID
                && $0.pinnedFolderID == target.pinnedFolderID
        }

        if target.pinnedFolderID != nil, target.sectionIndex == 0 {
            return nil
        }

        if target.pinnedFolderID == nil {
            if let folderFrame = pinnedFolderFrames.first(where: {
                $0.spaceID == target.spaceID && $0.firstSectionIndex == target.sectionIndex
            }) {
                return indicatorFrame(
                    alignedTo: folderFrame.frame,
                    yPosition: folderFrame.frame.minY,
                    horizontalInset: horizontalInset,
                    thickness: thickness
                )
            }

            if let folderFrame = pinnedFolderFrames.first(where: {
                $0.spaceID == target.spaceID && $0.afterSectionIndex == target.sectionIndex
            }) {
                return indicatorFrame(
                    alignedTo: folderFrame.frame,
                    yPosition: folderFrame.frame.maxY,
                    horizontalInset: horizontalInset,
                    thickness: thickness
                )
            }
        }

        if let previousRowFrame = sectionRowFrames.first(where: {
            ($0.folderChildIndex ?? $0.sectionIndex) == target.sectionIndex - 1
        }) {
            return indicatorFrame(
                alignedTo: previousRowFrame.frame,
                yPosition: previousRowFrame.frame.maxY,
                horizontalInset: horizontalInset,
                thickness: thickness
            )
        }

        if let targetRowFrame = sectionRowFrames.first(where: {
            ($0.folderChildIndex ?? $0.sectionIndex) == target.sectionIndex
        }) {
            return indicatorFrame(
                alignedTo: targetRowFrame.frame,
                yPosition: targetRowFrame.frame.minY,
                horizontalInset: horizontalInset,
                thickness: thickness
            )
        }

        if target.pinnedFolderID != nil {
            return nil
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
    let slot: BrowserSidebarTabDropSlot
    let distance: CGFloat
    let containsLocation: Bool
}
