// BrowserSpaceIconCatalog.swift

import AppKit
import os

// MARK: - BrowserSpaceIconCatalog

/// The icons a Space, folder or tab can use: symbols, or any emoji.
enum BrowserSpaceIconCatalog {
    struct EmojiCategory {
        let symbol: String
        let emoji: [String]
    }

    /// Eight columns of seven rows in the picker's Icon tab.
    static let systemImageNames = [
        "star.fill", "bookmark.fill", "heart.fill", "flag.fill", "bolt.fill", "triangle.fill", "asterisk", "bell.fill",
        "lightbulb.fill", "square.on.circle.fill", "square.grid.2x2.fill", "circle.grid.3x3.fill",
        "square.3.layers.3d", "cylinder.split.1x2.fill", "tray.2.fill", "square.on.square.fill",
        "folder.fill", "tray.fill", "calendar", "envelope.fill", "checkmark.square.fill", "doc.fill", "book.fill",
        "ellipsis.bubble.fill",
        "person.2.fill", "terminal.fill", "wrench.and.screwdriver.fill", "square.fill", "oval.portrait.fill",
        "circle.fill", "moon.fill", "sun.max.fill",
        "globe.americas.fill", "leaf.fill", "cloud.fill", "pawprint.fill", "basket.fill", "gift.fill",
        "bed.double.fill", "fork.knife",
        "dumbbell.fill", "airplane", "music.note", "paintpalette.fill", "video.fill", "bandage.fill",
        "chevron.left.forwardslash.chevron.right", "baseball.fill",
        "cloud", "map.fill", "flame.fill", "takeoutbag.and.cup.and.straw.fill", "theatermasks.fill", "scroll.fill",
        "hand.thumbsup.fill", "tram.fill",
    ]

    /// Emoji by category, built from Unicode so new ones need no list.
    static let emojiCategories: [EmojiCategory] = [
        EmojiCategory(symbol: "face.smiling", emoji: emoji(in: [
            0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9DF, 0x1F44A...0x1F450,
            0x1F466...0x1F487, 0x1F90C...0x1F90F, 0x1F918...0x1F91F, 0x1F9B0...0x1F9B9,
        ])),
        EmojiCategory(symbol: "sun.max", emoji: emoji(in: [
            0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344, 0x1F300...0x1F32C,
        ])),
        EmojiCategory(symbol: "cup.and.saucer", emoji: emoji(in: [
            0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB,
        ])),
        EmojiCategory(symbol: "medal", emoji: emoji(in: [
            0x1F380...0x1F3AF, 0x1F3C0...0x1F3CF, 0x1F945...0x1F94F, 0x1F93A...0x1F93F,
        ])),
        EmojiCategory(symbol: "box.truck", emoji: emoji(in: [0x1F680...0x1F6FC, 0x1F3D4...0x1F3F0])),
        EmojiCategory(symbol: "gift", emoji: emoji(in: [
            0x1F4A0...0x1F4FF, 0x1F50A...0x1F53D, 0x1F9E0...0x1F9FF, 0x1FA70...0x1FAFF,
        ])),
        EmojiCategory(symbol: "heart", emoji: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝",
            "⭐️", "✨", "⚡️", "🔥", "💧", "🌈", "☀️", "🌙", "☁️", "❄️", "⛄️", "♻️", "✅", "❌", "❓", "❗️", "⚠️", "🚫", "💯",
            "🔔", "🔕", "🎵", "🎶", "➕", "➖", "➗", "✖️", "♾️", "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "🟤", "⚫️", "⚪️",
        ]),
        EmojiCategory(symbol: "flag", emoji: ["🏳️", "🏴", "🏁", "🚩", "🏳️‍🌈"] + [
            "US", "GB", "DE", "FR", "ES", "IT", "PT", "NL", "BE", "CH", "AT", "SE", "NO", "FI", "DK", "IE", "PL", "CZ",
            "RO", "HU", "GR", "TR", "UA", "RU", "GE", "AM", "AZ", "KZ", "IL", "AE", "SA", "IN", "CN", "JP", "KR", "TH",
            "VN", "ID", "SG", "AU", "NZ", "CA", "MX", "BR", "AR", "CL", "ZA", "EG", "NG", "KE",
        ].map(flag)),
    ]

    /// The words a picker search matches against: an emoji's Unicode names.
    static func searchName(ofEmoji emoji: String) -> String {
        (emoji.applyingTransform(.toUnicodeName, reverse: false) ?? "")
            .replacingOccurrences(of: "\\N{", with: " ")
            .replacingOccurrences(of: "}", with: " ")
            .lowercased()
    }

    private static func emoji(in ranges: [ClosedRange<UInt32>]) -> [String] {
        ranges.flatMap { range in
            range.compactMap { value -> String? in
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation else { return nil }
                return String(scalar)
            }
        }
    }

    private static func flag(_ code: String) -> String {
        String(String.UnicodeScalarView(code.unicodeScalars.compactMap {
            Unicode.Scalar(0x1F1E6 + $0.value - 65)
        }))
    }
}

// MARK: - BrowserIconImage

/// Draws an icon name: a symbol, or an emoji stored with a prefix so older
/// versions keep treating the value as a plain string.
enum BrowserIconImage {
    private struct CacheKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: CGFloat
        let description: String?
    }

    /// Images are only read once made, so one instance can be shared across threads.
    private struct CachedImage: @unchecked Sendable {
        let image: NSImage?
    }

    private static let emojiPrefix = "emoji:"

    private static let cache = OSAllocatedUnfairLock(initialState: [CacheKey: CachedImage]())

    static func name(emoji: String) -> String { emojiPrefix + emoji }

    static func emoji(from name: String) -> String? {
        name.hasPrefix(emojiPrefix) ? String(name.dropFirst(emojiPrefix.count)) : nil
    }

    static func isValid(_ name: String) -> Bool {
        emoji(from: name) != nil || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The icon at a size and weight. Sidebar rows ask again on every refresh, so each
    /// image is made once and the same instance is handed out after that.
    static func image(
        named name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight = .regular,
        description: String? = nil,
    ) -> NSImage? {
        let key = CacheKey(name: name, pointSize: pointSize, weight: weight.rawValue, description: description)
        if let cached = cache.withLock({ $0[key] }) {
            return cached.image
        }
        let image: NSImage? =
            if let emoji = emoji(from: name) {
                emojiImage(emoji, pointSize: pointSize)
            } else {
                NSImage(systemSymbolName: name, accessibilityDescription: description)?
                    .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
            }
        cache.withLock { $0[key] = CachedImage(image: image) }
        return image
    }

    private static func emojiImage(_ emoji: String, pointSize: CGFloat) -> NSImage {
        let text = emoji as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pointSize)]
        let measured = text.size(withAttributes: attributes)
        let image = NSImage(
            size: NSSize(width: ceil(measured.width), height: ceil(measured.height)),
            flipped: false,
        ) { rect in
            text.draw(in: rect, withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}
