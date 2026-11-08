// BrowserWindowGeometry.swift

import CoreGraphics

enum BrowserWindowGeometry {
    static let browserContentCornerRadius: CGFloat = 6
    static let browserContentEdgeInset: CGFloat = 10
    static let windowCornerRadius: CGFloat = browserContentCornerRadius + browserContentEdgeInset

    /// A window for tabs dropped outside every window: the size of the window
    /// they came from, its top left corner a little up and left of the drop,
    /// inside the visible part of the screen under the drop. Screen
    /// coordinates, origin at the bottom left.
    /// As small as a browser window gets: the sidebar and a narrow page beside it.
    static let browserWindowMinimumSize = CGSize(width: 470, height: 382)

    /// Where a profile's first window keeps its frame between launches; a test
    /// run with its own runtime keeps its own.
    static func frameAutosaveName(profileID: String, runtimeSuffix: String?) -> String {
        (["OpenArc Window", profileID] + [runtimeSuffix].compactMap(\.self)).joined(separator: " ")
    }

    static func frame(droppedAt point: CGPoint, size: CGSize?, minSize: CGSize, visible: CGRect) -> CGRect {
        var size = size ?? CGSize(width: 1360, height: 860)
        size.width = min(max(size.width, minSize.width), visible.width)
        size.height = min(max(size.height, minSize.height), visible.height)
        let x = min(max(point.x - 40, visible.minX), visible.maxX - size.width)
        let top = min(max(point.y + 20, visible.minY + size.height), visible.maxY)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}
