import AppKit

// MARK: - BrowserSplitPaneLayout

/// Pane frames for a Split View inside the tab host view. The CEF controller
/// calls the Objective-C entry point on every host layout; Swift tests use the
/// typed one. Horizontal panes run left to right and vertical panes top to
/// bottom, whatever the host view's flipping.
@objc final class BrowserSplitPaneLayout: NSObject {
    /// Panes are as far apart as the content is from the window edge, as in
    /// a single page: the gap equals the content inset.
    static let paneGap: CGFloat = BrowserWindowGeometry.browserContentEdgeInset

    /// Accent border drawn inside the focused pane while a split is shown.
    @objc static let focusRingWidth: CGFloat = 2

    // MARK: Dividers

    /// A divider drag never shrinks a pane below this length, unless the two
    /// neighbors together are too short for it.
    static let minimumPaneLength: CGFloat = 220

    /// The divider snaps to equal neighbors within this distance.
    static let equalSnapDistance: CGFloat = 14

    /// The divider takes clicks across the whole gap and nowhere else.
    static let dividerHitOutset: CGFloat = 0

    /// Grip drawn in the middle of a divider while it is hovered or dragged.
    static let dividerGripSize = CGSize(width: 2, height: 24)

    @objc static var focusRingCornerRadius: CGFloat { BrowserChromeLayout.leadingContentCornerRadius }

    /// Every pane corner is rounded like the outer content corners.
    @objc static var paneCornerRadius: CGFloat { BrowserChromeLayout.leadingContentCornerRadius }

    @objc static var focusRingColor: NSColor { BrowserChromeColors.splitFocusedPaneBorder }

    static func frames(
        in bounds: CGRect,
        count: Int,
        orientation: BrowserTabSplitOrientation,
        fractions: [Double]?,
        flipped: Bool
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
        flipped: Bool
    ) -> [NSValue] {
        frames(
            in: bounds,
            count: count,
            orientation: vertical ? .vertical : .horizontal,
            fractions: fractions.isEmpty ? nil : fractions.map(\.doubleValue),
            flipped: flipped
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
                    height: max(first.height, second.height)
                ).insetBy(dx: -dividerHitOutset, dy: 0)
            }
            let lower = first.minY <= second.minY ? first : second
            let upper = lower == first ? second : first
            return CGRect(
                x: min(first.minX, second.minX),
                y: lower.maxY,
                width: max(first.width, second.width),
                height: max(upper.minY - lower.maxY, 0)
            ).insetBy(dx: 0, dy: -dividerHitOutset)
        }
    }

    /// Distance of `point` from the first pane's outer edge along the split axis.
    static func axisPosition(
        of point: CGPoint,
        in bounds: CGRect,
        orientation: BrowserTabSplitOrientation,
        flipped: Bool
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
        fractions: [Double]?
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
            end - minimum
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
            fractions: fractions.isEmpty ? nil : fractions.map(\.doubleValue)
        )?.map { NSNumber(value: $0) }
    }

    @objc(dividerFramesBetweenPaneFrames:vertical:) static func dividerFrames(
        between paneFrames: [NSValue],
        vertical: Bool
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
        fractions: [NSNumber]
    ) -> [NSNumber]? {
        let orientation: BrowserTabSplitOrientation = vertical ? .vertical : .horizontal
        return Self.fractions(
            movingDivider: index,
            to: axisPosition(of: point, in: bounds, orientation: orientation, flipped: flipped),
            length: vertical ? bounds.height : bounds.width,
            count: count,
            fractions: fractions.isEmpty ? nil : fractions.map(\.doubleValue)
        )?.map { NSNumber(value: $0) }
    }
}
