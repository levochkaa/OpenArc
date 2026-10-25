// BrowserSidebarTabDrag.swift

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
                        height: baseTileSide,
                    ),
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
