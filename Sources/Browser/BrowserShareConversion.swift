// BrowserShareConversion.swift

import AppKit
import Foundation

// MARK: - BrowserShareNode

/// A pinned tab or folder about to be shared, with its children in sidebar order.
indirect enum BrowserShareNode: Equatable {
    case tab(title: String?, urlString: String, faviconPNG: Data?)
    case folder(title: String?, icon: String?, children: [BrowserShareNode])
}

// MARK: - BrowserShareConversion

/// Turns a sidebar tree into what a link shares, and a shared Space or folder
/// back into a tree OpenArc adds.
enum BrowserShareConversion {
    // MARK: Internal

    /// Folders inside folders the server keeps; deeper ones give their tabs to the deepest kept folder.
    static let maximumFolderDepth = 8
    static let maximumItems = 1000
    /// A favicon or icon PNG larger than this is left out.
    static let maximumImageBytes = 12 * 1024
    static let faviconSide: CGFloat = 32
    static let iconSide: CGFloat = 64
    static let maximumQuoteLength = 2000
    /// Copy URL as Quote waits this long for the server before copying the page link.
    static let quotePublishTimeout = 5.0

    /// The tree depth first, each item naming its folder by index. Tabs that are
    /// not web pages stay out.
    static func items(from nodes: [BrowserShareNode]) -> [BrowserShareItem] {
        var items = [BrowserShareItem]()
        func add(_ nodes: [BrowserShareNode], parent: Int?, depth: Int) {
            for node in nodes where items.count < maximumItems {
                switch node {
                case .tab(let title, let urlString, let favicon):
                    guard isWebAddress(urlString) else { continue }
                    let png = favicon.flatMap { $0.count <= maximumImageBytes ? $0 : nil }
                    items.append(.tab(title: trimmed(title), urlString: urlString, faviconPNG: png, parent: parent))
                case .folder(let title, let icon, let children):
                    guard depth < maximumFolderDepth + 1 else {
                        add(children, parent: parent, depth: depth)
                        continue
                    }
                    items.append(.folder(title: trimmed(title), icon: icon.flatMap(symbolName), parent: parent))
                    add(children, parent: items.count - 1, depth: depth + 1)
                }
            }
        }
        add(nodes, parent: nil, depth: 0)
        return items
    }

    /// The tree a shared list describes, for adding it.
    static func importedNodes(from items: [BrowserShareItem]) -> [BrowserImportedSidebar.Node] {
        var children = [Int: [Int]]()
        var roots = [Int]()
        for (index, item) in items.enumerated() {
            if let parent = item.parent, parent < index, items[parent].kind == .folder {
                children[parent, default: []].append(index)
            } else {
                roots.append(index)
            }
        }
        func nodes(_ indices: [Int]) -> [BrowserImportedSidebar.Node] {
            indices.compactMap { index in
                let item = items[index]
                switch item.kind {
                case .tab:
                    guard let urlString = item.urlString, isWebAddress(urlString) else { return nil }
                    return .tab(title: nil, savedTitle: trimmed(item.title), urlString: urlString)
                case .folder:
                    return .folder(title: trimmed(item.title), icon: item.icon, children: nodes(children[index] ?? []))
                }
            }
        }
        return nodes(roots)
    }

    /// A shared Space as another browser's Space, for the sidebar import.
    static func importedSpace(from content: BrowserSharedContent) -> BrowserImportedSidebar.Space {
        BrowserImportedSidebar.Space(
            title: trimmed(content.title),
            icon: content.icon.flatMap(sidebarIcon),
            pinned: importedNodes(from: content.items),
            theme: BrowserImportedSidebar.theme(hexColors: content.colors),
        )
    }

    /// A shared folder as one folder holding its tree.
    static func importedFolder(from content: BrowserSharedContent) -> BrowserImportedSidebar.Node {
        .folder(title: trimmed(content.title), icon: content.icon, children: importedNodes(from: content.items))
    }

    /// `#RRGGBB` for a theme color.
    static func hex(_ color: BrowserSpaceTheme.Color) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    /// What a Space's icon name shares: its emoji, or its symbol name.
    static func sharedIcon(_ systemImageName: String) -> String? {
        BrowserIconImage.emoji(from: systemImageName) ?? symbolName(systemImageName)
    }

    /// An image drawn into a square PNG, nil when it would be too large to share.
    static func png(_ image: NSImage, side: CGFloat) -> Data? {
        guard let resized = BrowserImageThumbnailer.resizedImage(image, fitting: CGSize(width: side, height: side)),
              let cgImage = resized.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]),
              data.count <= maximumImageBytes
        else { return nil }
        return data
    }

    /// The page draws the icon on the Space's first color, or on its tile
    /// without one: blue on the tile, cream on a dark color, ink on a light one.
    static func iconInk(onColors colors: [String]) -> NSColor {
        guard let first = colors.first, let luminance = luminance(hex: first) else {
            return NSColor(srgbRed: 0x31 / 255, green: 0x39 / 255, blue: 0xFB / 255, alpha: 1)
        }
        return luminance < 0.4
            ? NSColor(srgbRed: 1, green: 0xFA / 255, blue: 0xDD / 255, alpha: 1)
            : NSColor(srgbRed: 0x1B / 255, green: 0x1D / 255, blue: 0x3A / 255, alpha: 1)
    }

    /// Relative luminance of `#RRGGBB`.
    static func luminance(hex: String) -> Double? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        func channel(_ shift: UInt32) -> Double {
            let component = Double((value >> shift) & 0xFF) / 255
            return component <= 0.039_28 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func isWebAddress(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host?.isEmpty == false
    }

    // MARK: Private

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A symbol name the server accepts: lowercase words and digits joined by dots.
    private static func symbolName(_ name: String) -> String? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let valid = !parts.isEmpty && name.count <= 64 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
        }
        return valid ? name : nil
    }

    /// An emoji comes back as an emoji icon name; a symbol as itself.
    private static func sidebarIcon(_ icon: String) -> String? {
        icon.unicodeScalars.allSatisfy(\.isASCII) ? symbolName(icon) : BrowserIconImage.name(emoji: icon)
    }
}
