// BrowserToolbarConfiguration.swift

import CoreGraphics
import Foundation

// MARK: - BrowserToolbarItem

/// What the top toolbar can hold: its built-in controls, or any browser command.
enum BrowserToolbarItem: Hashable {
    case back
    case forward
    case reload
    case copyLink
    case address
    case flexibleSpace
    case pinnedExtensions
    case splitView
    case siteControls
    case command(BrowserCommandID)

    /// Commands that make sense as a button, in the order the palette shows them.
    static let paletteCommands: [BrowserCommandID] = [
        .newTab, .toggleSidebar, .toggleBookmark, .viewDownloads, .viewLibrary, .openHistory, .findInPage,
        .shareTab, .translatePage, .togglePictureInPicture, .captureArea, .captureFullPage, .capturePortrait,
        .zoomIn, .zoomOut, .resetZoom, .printPage, .savePage, .archiveTab, .togglePinTab, .duplicateTab,
        .newLittleWindow, .newIncognitoWindow, .newWindow, .forceReload, .javaScriptConsole, .networkInspector,
        .inspectElements, .toggleDeveloperMode, .openExtensions, .muteAllTabs, .openSettings,
    ]

    /// Everything the palette offers, built-in controls first.
    static let palette: [BrowserToolbarItem] =
        [.back, .forward, .reload, .address, .copyLink, .flexibleSpace, .pinnedExtensions, .splitView, .siteControls]
            + paletteCommands.map(BrowserToolbarItem.command)

    private static let commandPrefix = "command:"

    var rawValue: String {
        switch self {
        case .back: "back"
        case .forward: "forward"
        case .reload: "reload"
        case .copyLink: "copyLink"
        case .address: "address"
        case .flexibleSpace: "flexibleSpace"
        case .pinnedExtensions: "pinnedExtensions"
        case .splitView: "splitView"
        case .siteControls: "siteControls"
        case .command(let id): Self.commandPrefix + id.rawValue
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "back": self = .back
        case "forward": self = .forward
        case "reload": self = .reload
        case "copyLink": self = .copyLink
        case "address": self = .address
        case "flexibleSpace": self = .flexibleSpace
        case "pinnedExtensions": self = .pinnedExtensions
        case "splitView": self = .splitView
        case "siteControls": self = .siteControls
        default:
            guard rawValue.hasPrefix(Self.commandPrefix),
                  let id = BrowserCommandID(rawValue: String(rawValue.dropFirst(Self.commandPrefix.count)))
            else { return nil }
            self = .command(id)
        }
    }
}

// MARK: - BrowserToolbarConfiguration

struct BrowserToolbarConfiguration: Equatable {
    /// The toolbar as it has always looked: navigation, centered address, actions.
    static let standard = BrowserToolbarConfiguration(items: [
        .back, .forward, .reload, .flexibleSpace, .copyLink, .address, .flexibleSpace,
        .pinnedExtensions, .splitView, .siteControls,
    ])

    private(set) var items: [BrowserToolbarItem]

    var storedValues: [String] { items.map(\.rawValue) }

    /// Palette items not on the toolbar. A flexible space stays available.
    var availableItems: [BrowserToolbarItem] {
        BrowserToolbarItem.palette.filter { $0 == .flexibleSpace || !items.contains($0) }
    }

    init(items: [BrowserToolbarItem]) {
        var seen = Set<BrowserToolbarItem>()
        // Only a flexible space can appear twice.
        self.items = items.filter { $0 == .flexibleSpace || seen.insert($0).inserted }
    }

    /// Unknown items from a newer or older version are dropped, not fatal.
    init(storedValues: [String]) {
        self.init(items: storedValues.compactMap(BrowserToolbarItem.init(rawValue:)))
    }

    // MARK: Layout

    /// Places items along a bar: fixed widths in order, and flexible spaces sharing
    /// what remains. Two flexible spaces center what stands between them, as far
    /// as the items on either side allow.
    static func spans(
        for widths: [CGFloat?],
        spacing: CGFloat,
        padding: CGFloat,
        length: CGFloat,
        flexibleMinimum: CGFloat = 0,
    ) -> [(start: CGFloat, width: CGFloat)] {
        let fixed = widths.compactMap(\.self).reduce(0, +)
        let flexibleIndices = widths.indices.filter { widths[$0] == nil }
        let gaps = spacing * CGFloat(max(widths.count - 1, 0))
        let free = max(length - padding * 2 - fixed - gaps, 0)
        var flexibleWidths = [Int: CGFloat]()
        if flexibleIndices.count == 2 {
            let before = widths[..<flexibleIndices[0]].compactMap(\.self).reduce(0, +)
            let after = widths[(flexibleIndices[1] + 1)...].compactMap(\.self).reduce(0, +)
            let first = min(max((free + after - before) / 2, 0), free)
            flexibleWidths[flexibleIndices[0]] = max(first, flexibleMinimum)
            flexibleWidths[flexibleIndices[1]] = max(free - first, flexibleMinimum)
        } else {
            for index in flexibleIndices {
                flexibleWidths[index] = max(free / CGFloat(flexibleIndices.count), flexibleMinimum)
            }
        }
        var x = padding
        return widths.enumerated().map { index, width in
            let span = (start: x, width: width ?? flexibleWidths[index] ?? 0)
            x += span.width + spacing
            return span
        }
    }

    /// `index` counts the current items, as the drop indicator shows them.
    mutating func move(from source: Int, to index: Int) {
        guard items.indices.contains(source) else { return }
        let item = items.remove(at: source)
        let target = source < index ? index - 1 : index
        items.insert(item, at: min(max(target, 0), items.count))
    }

    mutating func insert(_ item: BrowserToolbarItem, at index: Int) {
        if item != .flexibleSpace, let existing = items.firstIndex(of: item) {
            move(from: existing, to: index)
            return
        }
        items.insert(item, at: min(max(index, 0), items.count))
    }

    mutating func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
    }
}
