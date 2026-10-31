// BrowserSplitPaneLayout.swift

import AppKit

// MARK: - BrowserSplitPaneLayout

/// Pane frames for a Split View inside the tab host view. The CEF controller
/// calls the Objective-C entry point on every host layout; Swift tests use the
/// typed one. Horizontal panes run left to right and vertical panes top to
/// bottom, whatever the host view's flipping.
@objc final class BrowserSplitPaneLayout: NSObject {
    /// The edge of a page or pane that a tab dragged from the sidebar would
    /// split. The zones: min(W/3, 80) at the left and right edges and
    /// min(H/3, 50) at the top and bottom; in a corner the relatively closer
    /// edge wins. `pane` and `point` share flipped coordinates.
    enum PageDropEdge: Equatable {
        case leading, trailing, top, bottom

        // MARK: Internal

        var orientation: BrowserTabSplitOrientation {
            self == .leading || self == .trailing ? .horizontal : .vertical
        }

        /// A new pane on the leading or top edge goes before the pane it splits.
        var isBefore: Bool { self == .leading || self == .top }
    }

    /// Panes are as far apart as the content is from the window edge.
    static let paneGap: CGFloat = BrowserWindowGeometry.browserContentEdgeInset

    /// Accent border drawn inside the focused pane while a split is shown.
    @objc static let focusRingWidth: CGFloat = 2

    // MARK: Pane bar

    /// Each pane shows its own bar above the page while a split is visible
    /// (32 pt).
    @objc static let paneBarHeight: CGFloat = 32

    // MARK: Dividers

    /// A divider drag never shrinks a pane below this length, unless the two
    /// neighbors together are too short for it. It stops at 220 pt.
    static let minimumPaneLength: CGFloat = 220

    /// The divider snaps to equal neighbors within this distance.
    static let equalSnapDistance: CGFloat = 14

    /// The divider takes clicks across the whole gap and nowhere else.
    static let dividerHitOutset: CGFloat = 0

    /// Grip drawn in the middle of a divider while it is hovered or dragged.
    static let dividerGripSize = CGSize(width: 2, height: 24)

    /// Pane drag handle: a 24 × 2 grip at the top center of the focused
    /// pane. The hit area around it is larger so it is easy to grab.
    static let paneGripSize = CGSize(width: 24, height: 2)
    static let paneGripHitSize = CGSize(width: 56, height: 8)

    static let pageDropMaximumWidth: CGFloat = 80
    static let pageDropMaximumHeight: CGFloat = 50

    @objc static var focusRingCornerRadius: CGFloat { BrowserChromeLayout.leadingContentCornerRadius }

    /// Every pane corner is rounded like the outer content corners.
    @objc static var paneCornerRadius: CGFloat { BrowserChromeLayout.leadingContentCornerRadius }

    @objc static var focusRingColor: NSColor { BrowserChromeColors.splitFocusedPaneBorder }

    static func pageDropEdge(at point: CGPoint, in pane: CGRect) -> PageDropEdge? {
        guard pane.contains(point) else { return nil }
        let horizontal = min(pane.width / 3, pageDropMaximumWidth)
        let vertical = min(pane.height / 3, pageDropMaximumHeight)
        let candidates: [(PageDropEdge, CGFloat)] = [
            (.leading, (point.x - pane.minX) / horizontal),
            (.trailing, (pane.maxX - point.x) / horizontal),
            (.top, (point.y - pane.minY) / vertical),
            (.bottom, (pane.maxY - point.y) / vertical),
        ]
        return candidates.filter { $0.1 < 1 }.min { $0.1 < $1.1 }?.0
    }

    /// Half of the pane on the side the dropped tab will take.
    static func pageDropPreview(for edge: PageDropEdge, in pane: CGRect) -> CGRect {
        switch edge {
        case .leading: pane.divided(atDistance: pane.width / 2, from: .minXEdge).slice
        case .trailing: pane.divided(atDistance: pane.width / 2, from: .maxXEdge).slice
        case .top: pane.divided(atDistance: pane.height / 2, from: .minYEdge).slice
        case .bottom: pane.divided(atDistance: pane.height / 2, from: .maxYEdge).slice
        }
    }

    /// The pane a dragged pane lands on: the one under `point` along the split
    /// axis, or the first or last pane past either end. Frames are in pane order.
    static func paneIndex(at point: CGPoint, in frames: [CGRect], orientation: BrowserTabSplitOrientation) -> Int? {
        guard !frames.isEmpty else { return nil }
        let position = orientation == .horizontal ? point.x : point.y
        let centers = frames.map { orientation == .horizontal ? $0.midX : $0.midY }
        // Nearest center wins, so the gaps between panes split evenly.
        return centers.indices.min { abs(centers[$0] - position) < abs(centers[$1] - position) }
    }

    /// The page part of a pane, below its bar, in the host's coordinates.
    @objc(webContentFrameForPaneFrame:flipped:) static func webContentFrame(
        forPaneFrame pane: CGRect,
        flipped: Bool,
    ) -> CGRect {
        let bar = min(paneBarHeight, pane.height)
        return CGRect(
            x: pane.minX,
            y: flipped ? pane.minY + bar : pane.minY,
            width: pane.width,
            height: pane.height - bar,
        )
    }

    static func frames(
        in bounds: CGRect,
        count: Int,
        orientation: BrowserTabSplitOrientation,
        fractions: [Double]?,
        flipped: Bool,
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [bounds] }
        let isVertical = orientation == .vertical
        let length = isVertical ? bounds.height : bounds.width
        let available = max(length - paneGap * CGFloat(count - 1), 0)
        let weights = BrowserTabSplitGroupSessionSnapshot.validFractions(fractions, count: count)
            ?? Array(repeating: 1 / Double(count), count: count)
        // Round cumulative edges so neighboring panes never overlap or leave
        // a sub-point seam besides the fixed gap.
        var edges = [CGFloat(0)]
        var total = 0.0
        for weight in weights {
            total += weight
            edges.append((available * CGFloat(min(total, 1))).rounded())
        }
        edges[count] = available
        return (0..<count).map { index in
            let start = edges[index] + paneGap * CGFloat(index)
            let size = max(edges[index + 1] - edges[index], 0)
            if !isVertical {
                return CGRect(x: bounds.minX + start, y: bounds.minY, width: size, height: bounds.height)
            }
            let y = flipped ? bounds.minY + start : bounds.maxY - start - size
            return CGRect(x: bounds.minX, y: y, width: bounds.width, height: size)
        }
    }

    @objc(paneFramesInBounds:count:vertical:fractions:flipped:) static func paneFrames(
        in bounds: CGRect,
        count: Int,
        vertical: Bool,
        fractions: [NSNumber],
        flipped: Bool,
    ) -> [NSValue] {
        frames(
            in: bounds,
            count: count,
            orientation: vertical ? .vertical : .horizontal,
            fractions: fractions.isEmpty ? nil : fractions.map(\.doubleValue),
            flipped: flipped,
        ).map { NSValue(rect: $0) }
    }

    /// Hit frames of the dividers between consecutive panes.
    static func dividerFrames(between paneFrames: [CGRect], orientation: BrowserTabSplitOrientation) -> [CGRect] {
        zip(paneFrames, paneFrames.dropFirst()).map { first, second in
            if orientation == .horizontal {
                let leading = first.minX <= second.minX ? first : second
                let trailing = leading == first ? second : first
                return CGRect(
                    x: leading.maxX,
                    y: min(first.minY, second.minY),
                    width: max(trailing.minX - leading.maxX, 0),
                    height: max(first.height, second.height),
                ).insetBy(dx: -dividerHitOutset, dy: 0)
            }
            let lower = first.minY <= second.minY ? first : second
            let upper = lower == first ? second : first
            return CGRect(
                x: min(first.minX, second.minX),
                y: lower.maxY,
                width: max(first.width, second.width),
                height: max(upper.minY - lower.maxY, 0),
            ).insetBy(dx: 0, dy: -dividerHitOutset)
        }
    }

    /// Distance of `point` from the first pane's outer edge along the split axis.
    static func axisPosition(
        of point: CGPoint,
        in bounds: CGRect,
        orientation: BrowserTabSplitOrientation,
        flipped: Bool,
    ) -> CGFloat {
        if orientation == .horizontal {
            return point.x - bounds.minX
        }
        return flipped ? point.y - bounds.minY : bounds.maxY - point.y
    }

    /// Pane weights after dragging divider `index`, the one between panes
    /// `index` and `index + 1`, so that its gap centers on `position`. Only
    /// those two panes change; their total stays the same.
    static func fractions(
        movingDivider index: Int,
        to position: CGFloat,
        length: CGFloat,
        count: Int,
        fractions: [Double]?,
    ) -> [Double]? {
        guard count > 1, index >= 0, index < count - 1 else { return nil }
        let available = Double(length - paneGap * CGFloat(count - 1))
        guard available > 0 else { return nil }
        var weights = BrowserTabSplitGroupSessionSnapshot.validFractions(fractions, count: count)
            ?? Array(repeating: 1 / Double(count), count: count)
        let start = weights[..<index].reduce(0, +) * available
        let end = weights[...(index + 1)].reduce(0, +) * available
        let minimum = min(Double(minimumPaneLength), (end - start) / 2)
        var edge = min(
            max(Double(position - paneGap * CGFloat(index) - paneGap / 2), start + minimum),
            end - minimum,
        )
        let middle = (start + end) / 2
        if abs(edge - middle) <= Double(equalSnapDistance) {
            edge = middle
        }
        weights[index] = (edge - start) / available
        weights[index + 1] = (end - edge) / available
        return weights
    }

    /// Weights after a divider double click: its two neighbors become equal
    /// and every other pane keeps its size.
    static func equalizingNeighbors(ofDivider index: Int, count: Int, fractions: [Double]?) -> [Double]? {
        guard count > 1, index >= 0, index < count - 1 else { return nil }
        var weights = BrowserTabSplitGroupSessionSnapshot.validFractions(fractions, count: count)
            ?? Array(repeating: 1 / Double(count), count: count)
        let pair = weights[index] + weights[index + 1]
        weights[index] = pair / 2
        weights[index + 1] = pair / 2
        return weights
    }

    @objc(fractionsEqualizingNeighborsOfDivider:count:fractions:)
    static func equalizingNeighbors(ofDivider index: Int, count: Int, fractions: [NSNumber]) -> [NSNumber]? {
        equalizingNeighbors(
            ofDivider: index,
            count: count,
            fractions: fractions.isEmpty ? nil : fractions.map(\.doubleValue),
        )?.map { NSNumber(value: $0) }
    }

    @objc(dividerFramesBetweenPaneFrames:vertical:) static func dividerFrames(
        between paneFrames: [NSValue],
        vertical: Bool,
    ) -> [NSValue] {
        dividerFrames(between: paneFrames.map(\.rectValue), orientation: vertical ? .vertical : .horizontal)
            .map { NSValue(rect: $0) }
    }

    /// Weights after a divider drag in host view coordinates, or nil when the
    /// drag cannot apply.
    @objc(fractionsMovingDivider:toPoint:inBounds:count:vertical:flipped:fractions:) static func fractions(
        movingDivider index: Int,
        to point: CGPoint,
        in bounds: CGRect,
        count: Int,
        vertical: Bool,
        flipped: Bool,
        fractions: [NSNumber],
    ) -> [NSNumber]? {
        let orientation: BrowserTabSplitOrientation = vertical ? .vertical : .horizontal
        return Self.fractions(
            movingDivider: index,
            to: axisPosition(of: point, in: bounds, orientation: orientation, flipped: flipped),
            length: vertical ? bounds.height : bounds.width,
            count: count,
            fractions: fractions.isEmpty ? nil : fractions.map(\.doubleValue),
        )?.map { NSNumber(value: $0) }
    }
}
