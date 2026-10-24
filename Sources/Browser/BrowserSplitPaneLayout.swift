import AppKit

// MARK: - BrowserSplitPaneLayout

/// Pane frames for a Split View inside the tab host view. The CEF controller
/// calls the Objective-C entry point on every host layout; Swift tests use the
/// typed one. Horizontal panes run left to right and vertical panes top to
/// bottom, whatever the host view's flipping.
@objc final class BrowserSplitPaneLayout: NSObject {
    static let paneGap: CGFloat = 6

    /// Accent border drawn inside the focused pane while a split is shown.
    @objc static let focusRingWidth: CGFloat = 2

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
}
