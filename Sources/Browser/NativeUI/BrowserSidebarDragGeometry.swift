// BrowserSidebarDragGeometry.swift

import AppKit

// MARK: - BrowserSidebarDragRowGeometry

struct BrowserSidebarDragRowGeometry: Equatable {
    let item: BrowserSidebarItemID
    let container: BrowserSidebarDropContainer
    /// Visible row surface, including its nesting indent.
    let frame: CGRect
}

// MARK: - BrowserSidebarDropFeedback

enum BrowserSidebarDropFeedback: Equatable {
    case line(CGRect)
    case folder(String)
    case space(String)
    case app
}

// MARK: - BrowserSidebarDropProposal

struct BrowserSidebarDropProposal: Equatable {
    let destination: BrowserSidebarDropDestination
    let feedback: BrowserSidebarDropFeedback
    let previewSize: CGSize
}

// MARK: - BrowserSidebarDragGeometry

/// Rebuilt from a completed native layout, never inferred from old preferences.
/// Sibling identity describes the insertion; geometry only describes its visible affordance.
@MainActor struct BrowserSidebarDragGeometry {
    // MARK: Internal

    struct Slot {
        let proposal: BrowserSidebarDropProposal
        let hitFrame: CGRect
        let focusY: CGFloat
        let priority: Int
    }

    let listViewport: CGRect
    let appFrame: CGRect?
    let appEntryFrame: CGRect?
    let spaceHeaderFrame: CGRect?
    let rowWidth: CGFloat
    let rows: [BrowserSidebarDragRowGeometry]
    private(set) var slots: [Slot]
    let snapDistance: CGFloat

    init(
        tree: BrowserSidebarTabTree,
        payload: BrowserSidebarDragPayload,
        rows: [BrowserSidebarDragRowGeometry],
        listViewport: CGRect,
        spaceHeader: (id: String, frame: CGRect)?,
        appFrame: CGRect?,
        rowWidth: CGFloat,
        spacing: CGFloat = BrowserChromeLayout.sidebarListSpacing,
        appEntryFrame: CGRect? = nil,
    ) {
        self.listViewport = listViewport
        self.appFrame = appFrame
        self.appEntryFrame = appEntryFrame
        self.spaceHeaderFrame = spaceHeader?.frame
        self.rowWidth = rowWidth
        self.rows = rows
        let visible = rows.sorted { $0.frame.minY < $1.frame.minY }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.item, $0) })
        var slots = [Slot]()
        let thickness = BrowserChromeLayout.sidebarDropIndicatorThickness
        let snap = BrowserChromeLayout.sidebarTabDropVerticalSnapDistance
        let indent = BrowserChromeLayout.sidebarPinnedFolderTabIndent

        func firstDestination(_ container: BrowserSidebarDropContainer) -> BrowserSidebarDropDestination {
            .init(container: container, beforeItem: tree.items(in: container).first)
        }
        var visibleSuccessors = [BrowserSidebarItemID: BrowserSidebarItemID]()
        for container in Set(rows.map(\.container)) {
            let siblings = tree.items(in: container).filter { byID[$0] != nil }
            for (current, next) in zip(siblings, siblings.dropFirst()) {
                visibleSuccessors[current] = next
            }
        }
        func after(_ row: BrowserSidebarDragRowGeometry) -> BrowserSidebarDropDestination {
            .init(container: row.container, beforeItem: visibleSuccessors[row.item])
        }
        func line(_ frame: CGRect, y: CGFloat) -> BrowserSidebarDropFeedback? {
            let rect = CGRect(
                x: frame.minX + 6,
                y: y - thickness / 2,
                width: max(frame.width - 12, 0),
                height: thickness,
            )
            // A clipped/offscreen insertion line must never advertise a hidden drop.
            guard rect.width > 0, rect.minY >= listViewport.minY, rect.maxY <= listViewport.maxY else { return nil }
            return .line(rect)
        }
        func append(
            _ destination: BrowserSidebarDropDestination,
            feedback: BrowserSidebarDropFeedback?,
            frame: CGRect,
            focus: CGFloat,
            size: CGSize,
            priority: Int,
        ) {
            guard let feedback else { return }
            let hitFrame: CGRect =
                switch feedback {
                case .app,
                     .space: frame
                default: frame.intersection(listViewport)
                }
            guard !hitFrame.isNull, hitFrame.height > 0, hitFrame.width > 0 else { return }
            slots.append(Slot(
                proposal: .init(destination: destination, feedback: feedback, previewSize: size),
                hitFrame: hitFrame,
                focusY: focus,
                priority: priority,
            ))
        }
        for row in visible {
            let frame = row.frame
            guard frame.intersects(listViewport) else { continue }
            // New Tab, dividers and labels also occupy rows. Never average across
            // them by treating only draggable rows as visual neighbours.
            let above = frame.minY - spacing / 2
            let below = frame.maxY + spacing / 2
            let before = BrowserSidebarDropDestination(container: row.container, beforeItem: row.item)
            let size = CGSize(width: frame.width, height: BrowserChromeLayout.sidebarRowHeight)
            switch row.item {
            case .tab:
                var beforeFeedback = line(frame, y: above)
                if let parent = row.container.folderID,
                   tree.items(in: row.container).first == row.item,
                   byID[.folder(parent)].map({ listViewport.contains($0.frame) }) == true
                {
                    beforeFeedback = .folder(parent)
                }
                append(
                    before,
                    feedback: beforeFeedback,
                    frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2),
                    focus: above,
                    size: size,
                    priority: 2,
                )
                append(
                    after(row),
                    feedback: line(frame, y: below),
                    frame: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2),
                    focus: below,
                    size: size,
                    priority: 2,
                )
            case .folder(let id):
                let edge = min(8, frame.height / 4)
                append(
                    before,
                    feedback: line(frame, y: above),
                    frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: edge),
                    focus: above,
                    size: size,
                    priority: 1,
                )
                let inside = BrowserSidebarDropContainer.pinned(row.container.spaceID!, folderID: id)
                append(
                    firstDestination(inside),
                    feedback: .folder(id),
                    frame: CGRect(
                        x: frame.minX,
                        y: frame.minY + edge,
                        width: frame.width,
                        height: frame.height - edge,
                    ),
                    focus: frame.midY,
                    size: CGSize(width: max(frame.width - indent, 1), height: size.height),
                    priority: 0,
                )
                let descendants = tree.descendantFolderIDs(including: id)
                let block = visible.filter { candidate in
                    candidate.item == row.item || candidate.container.folderID.map { descendants.contains($0) } == true
                }
                let bottom = block.map(\.frame.maxY).max() ?? frame.maxY
                let gapY = bottom + spacing / 2
                // The outside insertion follows the whole expanded subtree, never the folder header.
                append(
                    after(row),
                    feedback: line(frame, y: gapY),
                    frame: CGRect(x: frame.minX, y: bottom, width: frame.width, height: spacing),
                    focus: gapY,
                    size: size,
                    priority: 1,
                )
            }
        }
        if let header = spaceHeader {
            let container = BrowserSidebarDropContainer.pinned(header.id)
            append(
                firstDestination(container),
                feedback: .space(header.id),
                frame: header.frame,
                focus: header.frame.midY,
                size: CGSize(width: rowWidth, height: BrowserChromeLayout.sidebarRowHeight),
                priority: 0,
            )
        }
        // Empty sections are supplied as actual insertion gaps by the view, not fabricated row estimates.
        if let appFrame, appFrame.width > 0, appFrame.height > 0 {
            let remaining = tree.items(in: .app).filter { item in
                if case .tab(let id) = item {
                    return !payload.tabIDs.contains(id)
                }
                return true
            }
            let frames = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
                .frames(for: remaining.count + 1, availableWidth: appFrame.width)
            for (index, frame) in frames.enumerated() {
                let frame = frame.offsetBy(dx: appFrame.minX, dy: appFrame.minY)
                let hit = frame.intersection(appFrame)
                guard !hit.isNull, hit.height > 0 else { continue }
                append(
                    .init(container: .app, beforeItem: remaining.dropFirst(index).first),
                    feedback: .app,
                    frame: hit,
                    focus: hit.midY,
                    size: frame.size,
                    priority: 0,
                )
            }
            let originalCount = tree.items(in: .app).count
            if originalCount > 0, originalCount % BrowserSidebarAppTabGridLayout.maxColumns == 0,
               remaining.count == originalCount, frames.count > originalCount, let last = frames.last
            {
                let originalHeight = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
                    .height(for: originalCount, availableWidth: appFrame.width)
                let entry = CGRect(
                    x: appFrame.minX,
                    y: appFrame.minY + originalHeight - 6,
                    width: appFrame.width,
                    height: 6,
                )
                append(
                    .init(container: .app),
                    feedback: .app,
                    frame: entry,
                    focus: entry.midY,
                    size: last.size,
                    priority: 0,
                )
            }
        }
        if let entry = appEntryFrame,
           let size = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)
            .frames(for: 1, availableWidth: rowWidth)
            .first?
            .size
        {
            append(.init(container: .app), feedback: .app, frame: entry, focus: entry.midY, size: size, priority: 0)
        }
        self.slots = slots
        self.snapDistance = snap
    }

    mutating func addEmptySection(_ container: BrowserSidebarDropContainer, frame: CGRect) {
        let line = CGRect(x: frame.minX + 6, y: frame.midY - 1, width: max(frame.width - 12, 0), height: 2)
        guard line.minY >= listViewport.minY, line.maxY <= listViewport.maxY else { return }
        slots.append(Slot(
            proposal: .init(
                destination: .init(container: container),
                feedback: .line(line),
                previewSize: CGSize(
                    width: frame.width,
                    height: BrowserChromeLayout.sidebarRowHeight,
                ),
            ),
            hitFrame: frame,
            focusY: frame.midY,
            priority: 2,
        ))
    }

    func proposal(at point: CGPoint, previous: BrowserSidebarDropProposal?) -> BrowserSidebarDropProposal? {
        guard listViewport.contains(point) || appFrame?.contains(point) == true
            || spaceHeaderFrame?.contains(point) == true || appEntryFrame?.contains(point) == true else { return nil }
        if let previous, let retained = slots.first(where: {
            $0.proposal.destination == previous.destination
                && sameFeedbackKind($0.proposal.feedback, previous.feedback)
                && $0.hitFrame.insetBy(dx: 0, dy: -3).contains(point)
        }) {
            return retained.proposal
        }
        let direct = slots.filter { $0.hitFrame.contains(point) }
        if direct.isEmpty, listViewport.contains(point), rows.contains(where: { $0.frame.contains(point) }) {
            return nil
        }
        // Use the geometry before validity filtering: a no-op must not jump to a distant valid slot.
        let candidates = direct.isEmpty
            ? slots.filter {
                point.x >= $0.hitFrame.minX - 8 && point.x <= $0.hitFrame.maxX + 8
                    && abs(point.y - $0.focusY) <= snapDistance
            }
            : direct
        guard !candidates.isEmpty else { return nil }
        if let previous,
           let retained = candidates
            .first(where: {
                $0.proposal.destination == previous.destination && $0.proposal.feedback == previous.feedback
            })
        {
            return retained.proposal
        }
        if direct.isEmpty, let previous, let retained = slots.first(where: {
            $0.proposal.destination == previous.destination && $0.hitFrame.insetBy(dx: 0, dy: -3).contains(point)
        }) {
            return retained.proposal
        }
        return candidates.min {
            let a = abs(point.y - $0.focusY)
            let b = abs(point.y - $1.focusY)
            if abs(a - b) > 0.25 {
                return a < b
            }
            return $0.priority < $1.priority
        }?.proposal
    }

    // MARK: Private

    private func sameFeedbackKind(_ lhs: BrowserSidebarDropFeedback, _ rhs: BrowserSidebarDropFeedback) -> Bool {
        switch (lhs, rhs) {
        case (.app, .app),
             (.line, .line): true
        case (.folder(let a), .folder(let b)),
             (.space(let a), .space(let b)): a == b
        default: false
        }
    }
}
