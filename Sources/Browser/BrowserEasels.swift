// BrowserEasels.swift

import AppKit
import Foundation

// MARK: - BrowserEaselURL

/// An Easel lives in the sidebar as a pinned tab at `openarc://easel/<id>`. The
/// engine shows an empty page there and the window draws the canvas over it.
enum BrowserEaselURL {
    static let host = "easel"

    static func urlString(forEaselID id: String) -> String {
        "\(BrowserInternalURLNormalizer.canonicalScheme)://\(host)/\(id)"
    }

    /// The Easel's ID, or nil for any other address.
    static func easelID(from urlString: String?) -> String? {
        guard let urlString, let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == BrowserInternalURLNormalizer.canonicalScheme,
              components.host?.lowercased() == host
        else { return nil }
        let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty, !id.contains("/"), id.count <= 64,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return id
    }

    static func isEasel(_ urlString: String?) -> Bool {
        easelID(from: urlString) != nil
    }
}

// MARK: - BrowserEaselColor

/// The palette's named colors. Black and white trade places in dark mode.
enum BrowserEaselColor: String, Codable, CaseIterable {
    case black
    case yellow
    case pink
    case red
    case lightGreen
    case darkGreen
    case white
    case gray
    case purple
    case lightBlue
    case darkBlue

    // MARK: Internal

    /// The picker's two rows.
    static let pickerRows: [[BrowserEaselColor]] = [
        [.black, .yellow, .pink, .red, .lightGreen, .darkGreen],
        [.white, .gray, .purple, .lightBlue, .darkBlue],
    ]

    func rgb(palette: BrowserEaselPalette, isDark: Bool) -> UInt32 {
        switch self {
        case .black: return isDark ? 0xFFFFFF : 0x000000
        case .white: return isDark ? 0x000000 : 0xFFFFFF
        case .gray: return 0xBBBBBB
        default: break
        }
        switch palette {
        case .chill:
            switch self {
            case .pink: return 0xF2C2AC
            case .red: return 0xD74807
            case .yellow: return 0xC2A12A
            case .lightGreen: return 0xD0D87F
            case .darkGreen: return 0x1D5914
            case .lightBlue: return 0x55A2BD
            case .darkBlue: return 0x3139FB
            default: return 0xA6729D
            }
        case .vibrant:
            switch self {
            case .pink: return 0xFF994E
            case .red: return 0xF53714
            case .yellow: return 0xFFD335
            case .lightGreen: return 0x34E895
            case .darkGreen: return 0x107A00
            case .lightBlue: return 0x00C7F3
            case .darkBlue: return 0x3139FB
            default: return 0xC0009F
            }
        }
    }

    func color(palette: BrowserEaselPalette, isDark: Bool) -> NSColor {
        let value = rgb(palette: palette, isDark: isDark)
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1,
        )
    }
}

// MARK: - BrowserEaselPalette

enum BrowserEaselPalette: String, Codable, CaseIterable {
    case vibrant
    case chill

    var title: String {
        switch self {
        case .vibrant: BrowserStrings.easelPaletteVibrant
        case .chill: BrowserStrings.easelPaletteChill
        }
    }
}

// MARK: - BrowserEaselTextStyle

/// Paragraph styles from the largest to body text. Headings are centered.
enum BrowserEaselTextStyle: String, Codable, CaseIterable {
    case ultra
    case h0
    case h1
    case h2
    case body

    var larger: BrowserEaselTextStyle? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    var smaller: BrowserEaselTextStyle? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index < all.count - 1 else { return nil }
        return all[index + 1]
    }
}

// MARK: - BrowserEaselFont

enum BrowserEaselFont: String, Codable, CaseIterable {
    case clean
    case hip
    case fancy
    case mono

    // MARK: Internal

    var next: BrowserEaselFont {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var lineHeight: CGFloat {
        switch self {
        case .clean: 1.2
        case .hip: 1.28
        case .fancy: 1.32
        case .mono: 1.48
        }
    }

    /// Point size in Easel points and weight for a paragraph style.
    func metrics(for style: BrowserEaselTextStyle) -> (size: CGFloat, weight: NSFont.Weight) {
        switch (self, style) {
        case (.mono, .ultra): (80, .bold)
        case (.mono, .h0): (60, .bold)
        case (.mono, .h1): (44, .bold)
        case (.mono, .h2): (24, .bold)
        case (.mono, .body): (15, .regular)
        case (.fancy, .ultra): (80, .regular)
        case (.fancy, .h0): (60, .regular)
        case (.fancy, .h1): (48, .regular)
        case (.fancy, .h2): (28, .regular)
        case (.fancy, .body): (16, .regular)
        case (.hip, .ultra): (80, .black)
        case (.hip, .h0): (60, .black)
        case (.hip, .h1): (44, .black)
        case (.hip, .h2): (21, .bold)
        case (.hip, .body): (18, .regular)
        case (.clean, .ultra): (80, .heavy)
        case (.clean, .h0): (60, .heavy)
        case (.clean, .h1): (44, .heavy)
        case (.clean, .h2): (24, .bold)
        case (.clean, .body): (15, .regular)
        }
    }

    func font(style: BrowserEaselTextStyle, scale: CGFloat) -> NSFont {
        let (size, weight) = metrics(for: style)
        let pointSize = max(size * scale, 1)
        switch self {
        case .clean, .hip:
            return .systemFont(ofSize: pointSize, weight: weight)
        case .mono:
            return .monospacedSystemFont(ofSize: pointSize, weight: weight)
        case .fancy:
            let base = NSFont.systemFont(ofSize: pointSize, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return NSFont(descriptor: descriptor, size: pointSize) ?? base
        }
    }
}

// MARK: - BrowserEaselShapeKind

enum BrowserEaselShapeKind: String, Codable, CaseIterable {
    case rectangle
    case circle
    case arrow
    case freehand

    var defaultColor: BrowserEaselColor {
        switch self {
        case .rectangle: .lightGreen
        case .circle: .red
        case .arrow: .lightBlue
        case .freehand: .black
        }
    }
}

// MARK: - BrowserEaselText

struct BrowserEaselText: Codable, Equatable {
    var string: String
    var style = BrowserEaselTextStyle.body
    var font = BrowserEaselFont.clean
    /// The text that names the Easel.
    var isTitle = false
}

// MARK: - BrowserEaselShape

struct BrowserEaselShape: Codable, Equatable {
    var kind: BrowserEaselShapeKind
    var color: BrowserEaselColor
    /// A drawing's points, each from 0 to 1 within the frame.
    var points = [CGPoint]()
    /// An arrow's tail and tip, each from 0 to 1 within the frame.
    var arrowStart = CGPoint(x: 0, y: 0)
    var arrowEnd = CGPoint(x: 1, y: 1)
}

// MARK: - BrowserEaselImage

struct BrowserEaselImage: Codable, Equatable {
    /// The picture's file in the Easel's folder.
    var fileName: String
    var altText: String?
}

// MARK: - BrowserEaselCapture

/// Part of a page: its picture, where it came from, and whether it refreshes
/// from the open page while the Easel is on screen.
struct BrowserEaselCapture: Codable, Equatable {
    var fileName: String
    var urlString: String
    var title: String
    /// The outlined part of the page's visible area, each value from 0 to 1.
    var region: CGRect
    var isLive = false
    var capturedAt: Date
}

// MARK: - BrowserEaselContent

enum BrowserEaselContent: Codable, Equatable {
    case text(BrowserEaselText)
    case shape(BrowserEaselShape)
    case image(BrowserEaselImage)
    case capture(BrowserEaselCapture)

    // MARK: Internal

    var text: BrowserEaselText? {
        if case .text(let text) = self {
            text
        } else {
            nil
        }
    }

    var shape: BrowserEaselShape? {
        if case .shape(let shape) = self {
            shape
        } else {
            nil
        }
    }

    var capture: BrowserEaselCapture? {
        if case .capture(let capture) = self {
            capture
        } else {
            nil
        }
    }

    /// Pictures the object keeps in the Easel's folder.
    var fileNames: [String] {
        switch self {
        case .image(let image): [image.fileName]
        case .capture(let capture): [capture.fileName]
        default: []
        }
    }
}

// MARK: - BrowserEaselObject

struct BrowserEaselObject: Codable, Equatable, Identifiable {
    var id: String
    /// In Easel points: the document is 1000 points wide and scales with the view.
    var frame: CGRect
    var content: BrowserEaselContent

    init(id: String = UUID().uuidString, frame: CGRect, content: BrowserEaselContent) {
        self.id = id
        self.frame = frame
        self.content = content
    }
}

// MARK: - BrowserEaselDocument

struct BrowserEaselDocument: Codable, Equatable, Identifiable {
    // MARK: Internal

    static let width: CGFloat = 1000
    static let titleFrame = CGRect(x: 200, y: 35, width: 600, height: 72)

    var id: String
    var palette = BrowserEaselPalette.vibrant
    var usesAlignmentGuides = true
    var createdAt: Date
    var modifiedAt: Date
    /// Back to front.
    var objects: [BrowserEaselObject]

    /// The title text's words, or the default name.
    var title: String {
        let string = titleObject?.content.text?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return string.isEmpty ? BrowserStrings.easelUntitled : string
    }

    var titleObject: BrowserEaselObject? {
        objects.first { $0.content.text?.isTitle == true }
    }

    /// Where the content ends, in Easel points.
    var contentBottom: CGFloat {
        objects.map(\.frame.maxY).max() ?? 0
    }

    var fileNames: Set<String> {
        Set(objects.flatMap(\.content.fileNames))
    }

    /// A new Easel holds only its title.
    static func new(id: String = UUID().uuidString, title: String? = nil, now: Date = Date()) -> Self {
        Self(
            id: id,
            createdAt: now,
            modifiedAt: now,
            objects: [BrowserEaselObject(
                frame: titleFrame,
                content: .text(BrowserEaselText(
                    string: title ?? BrowserStrings.easelUntitled,
                    style: .h2,
                    isTitle: true,
                )),
            )],
        )
    }

    func index(of id: String) -> Int? {
        objects.firstIndex { $0.id == id }
    }

    func object(_ id: String) -> BrowserEaselObject? {
        objects.first { $0.id == id }
    }
}

// MARK: - BrowserEaselStore

/// Easels on disk: `Easels/<id>/easel.json` and its pictures beside the session.
/// Every window reads the same store, so a change shows wherever the Easel is open.
@MainActor final class BrowserEaselStore {
    // MARK: Internal

    static let didChangeNotification = Notification.Name("BrowserEaselStoreDidChange")

    /// The app's Easels; the app points it at `Easels` beside the session at launch.
    static var shared = BrowserEaselStore(directory: nil)

    // MARK: Private

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    let directory: URL?

    private var documents = [String: BrowserEaselDocument]()
    private var imagesByKey = [String: NSImage]()
    /// Pictures of a store without a folder, as in tests.
    private var memoryImageData = [String: Data]()
    private var loadedAll = false

    /// Newest first.
    var allDocuments: [BrowserEaselDocument] {
        loadAllIfNeeded()
        return documents.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    init(directory: URL?) {
        self.directory = directory
    }

    func document(id: String) -> BrowserEaselDocument? {
        if let document = documents[id] { return document }
        guard let url = documentURL(id), let data = try? Data(contentsOf: url),
              let document = try? Self.decoder.decode(BrowserEaselDocument.self, from: data)
        else { return nil }
        documents[id] = document
        return document
    }

    func save(_ document: BrowserEaselDocument) {
        guard documents[document.id] != document else { return }
        documents[document.id] = document
        if let url = documentURL(document.id), let data = try? Self.encoder.encode(document) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try? data.write(to: url, options: .atomic)
            removeUnusedFiles(of: document)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: ["id": document.id])
    }

    func delete(id: String) {
        documents.removeValue(forKey: id)
        imagesByKey = imagesByKey.filter { !$0.key.hasPrefix(id + "/") }
        if let folder = folderURL(id) {
            try? FileManager.default.removeItem(at: folder)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: ["id": id])
    }

    /// Keeps a picture for an Easel and returns its file name.
    func addImage(_ data: Data, toEaselID id: String, fileExtension: String = "png") -> String {
        let name = "\(UUID().uuidString).\(fileExtension)"
        writeImage(data, named: name, easelID: id)
        return name
    }

    /// Replaces a picture's file, as a live capture refreshes.
    func writeImage(_ data: Data, named name: String, easelID id: String) {
        imagesByKey["\(id)/\(name)"] = NSImage(data: data)
        if let folder = folderURL(id) {
            let images = folder.appendingPathComponent("images", isDirectory: true)
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try? data.write(to: images.appendingPathComponent(name), options: .atomic)
        } else {
            memoryImageData["\(id)/\(name)"] = data
        }
    }

    func image(named name: String, easelID id: String) -> NSImage? {
        let key = "\(id)/\(name)"
        if let image = imagesByKey[key] { return image }
        guard let data = imageData(named: name, easelID: id), let image = NSImage(data: data) else { return nil }
        imagesByKey[key] = image
        return image
    }

    func imageData(named name: String, easelID id: String) -> Data? {
        if let data = memoryImageData["\(id)/\(name)"] { return data }
        guard let folder = folderURL(id) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(name))
    }

    private func folderURL(_ id: String) -> URL? {
        guard BrowserEaselURL.easelID(from: BrowserEaselURL.urlString(forEaselID: id)) == id else { return nil }
        return directory?.appendingPathComponent(id, isDirectory: true)
    }

    private func documentURL(_ id: String) -> URL? {
        folderURL(id)?.appendingPathComponent("easel.json")
    }

    private func loadAllIfNeeded() {
        guard !loadedAll else { return }
        loadedAll = true
        guard let directory,
              let folders = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
              )
        else { return }
        for folder in folders where documents[folder.lastPathComponent] == nil {
            _ = document(id: folder.lastPathComponent)
        }
    }

    /// Pictures of deleted objects go once the Easel no longer names them.
    private func removeUnusedFiles(of document: BrowserEaselDocument) {
        guard let images = folderURL(document.id)?.appendingPathComponent("images", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(atPath: images.path)
        else { return }
        let used = document.fileNames
        for file in files where !used.contains(file) {
            // A picture added moments ago may belong to an object an undo brings back.
            let url = images.appendingPathComponent(file)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if Date().timeIntervalSince(created) > 600 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - BrowserEaselTool

enum BrowserEaselTool: String, CaseIterable {
    case pointer
    case image
    case text
    case circle
    case rectangle
    case arrow
    case freehand

    // MARK: Internal

    /// The key that picks the tool on the canvas; the image picker has none.
    var key: String? {
        switch self {
        case .pointer: "v"
        case .image: nil
        case .text: "t"
        case .circle: "o"
        case .rectangle: "r"
        case .arrow: "a"
        case .freehand: "p"
        }
    }

    var symbol: String {
        switch self {
        case .pointer: "cursorarrow"
        case .image: "photo"
        case .text: "character"
        case .circle: "circle"
        case .rectangle: "square"
        case .arrow: "arrow.up.right"
        case .freehand: "scribble"
        }
    }

    var title: String {
        switch self {
        case .pointer: BrowserStrings.easelToolPointer
        case .image: BrowserStrings.easelToolImage
        case .text: BrowserStrings.easelToolText
        case .circle: BrowserStrings.easelToolCircle
        case .rectangle: BrowserStrings.easelToolRectangle
        case .arrow: BrowserStrings.easelToolArrow
        case .freehand: BrowserStrings.easelToolPen
        }
    }

    var shapeKind: BrowserEaselShapeKind? {
        switch self {
        case .circle: .circle
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .freehand: .freehand
        default: nil
        }
    }
}

// MARK: - BrowserEaselHandle

/// A selected object's corner, or an arrow's end.
enum BrowserEaselHandle: Equatable {
    case topLeft, topRight, bottomLeft, bottomRight
    case arrowStart, arrowEnd
}

// MARK: - BrowserEaselEditor

/// Edits one Easel: every change is one undo step, saved at once.
@MainActor final class BrowserEaselEditor {
    // MARK: Internal

    static let minimumSize: CGFloat = 8
    static let defaultShapeSize: CGFloat = 150
    static let snapDistance: CGFloat = 5

    private(set) var document: BrowserEaselDocument
    var selectedObjectID: String? {
        didSet { if oldValue != selectedObjectID { onSelectionChange?() } }
    }

    var tool = BrowserEaselTool.pointer
    /// The title the sidebar row showed when the two were last matched.
    var syncedTitle: String?
    let undoManager = UndoManager()
    /// After every document change, with the new document.
    var onChange: ((BrowserEaselDocument) -> Void)?
    var onSelectionChange: (() -> Void)?

    // MARK: Private

    private let now: () -> Date

    var selectedObject: BrowserEaselObject? {
        selectedObjectID.flatMap(document.object)
    }

    init(document: BrowserEaselDocument, now: @escaping () -> Date = Date.init) {
        self.document = document
        self.now = now
        undoManager.groupsByEvent = false
    }

    // MARK: Geometry

    /// The frame after dragging `handle` to `point`, with the opposite corner held.
    static func resizedFrame(
        _ frame: CGRect,
        handle: BrowserEaselHandle,
        to point: CGPoint,
        keepsAspect: Bool,
    ) -> CGRect {
        let anchor =
            switch handle {
            case .topLeft: CGPoint(x: frame.maxX, y: frame.maxY)
            case .topRight: CGPoint(x: frame.minX, y: frame.maxY)
            case .bottomLeft: CGPoint(x: frame.maxX, y: frame.minY)
            case .arrowEnd, .arrowStart, .bottomRight: CGPoint(x: frame.minX, y: frame.minY)
            }
        var width = max(abs(point.x - anchor.x), minimumSize)
        var height = max(abs(point.y - anchor.y), minimumSize)
        if keepsAspect, frame.width > 0, frame.height > 0 {
            let ratio = frame.width / frame.height
            if width / height > ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
        }
        let x = point.x < anchor.x ? anchor.x - width : anchor.x
        let y = point.y < anchor.y ? anchor.y - height : anchor.y
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// An arrow with one end moved: new frame and both ends within it.
    static func movedArrow(
        frame: CGRect,
        shape: BrowserEaselShape,
        handle: BrowserEaselHandle,
        to point: CGPoint,
    ) -> (CGRect, BrowserEaselShape) {
        var start = CGPoint(
            x: frame.minX + shape.arrowStart.x * frame.width,
            y: frame.minY + shape.arrowStart.y * frame.height,
        )
        var end = CGPoint(
            x: frame.minX + shape.arrowEnd.x * frame.width,
            y: frame.minY + shape.arrowEnd.y * frame.height,
        )
        if handle == .arrowStart { start = point } else { end = point }
        var bounds = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y),
        )
        if bounds.width < 1 { bounds = bounds.insetBy(dx: -0.5, dy: 0) }
        if bounds.height < 1 { bounds = bounds.insetBy(dx: 0, dy: -0.5) }
        var moved = shape
        moved.arrowStart = CGPoint(
            x: (start.x - bounds.minX) / bounds.width,
            y: (start.y - bounds.minY) / bounds.height,
        )
        moved.arrowEnd = CGPoint(x: (end.x - bounds.minX) / bounds.width, y: (end.y - bounds.minY) / bounds.height)
        return (bounds, moved)
    }

    /// Snaps a moving frame's edges and center to the page's center and to the
    /// other objects' edges and centers. Returns the offset and the guide lines
    /// as vertical x and horizontal y values.
    static func snapOffset(
        for frame: CGRect,
        among others: [CGRect],
        distance: CGFloat = snapDistance,
    ) -> (offset: CGPoint, verticals: [CGFloat], horizontals: [CGFloat]) {
        let xs = [frame.minX, frame.midX, frame.maxX]
        let ys = [frame.minY, frame.midY, frame.maxY]
        var targetXs: [CGFloat] = [BrowserEaselDocument.width / 2]
        var targetYs = [CGFloat]()
        for other in others {
            targetXs += [other.minX, other.midX, other.maxX]
            targetYs += [other.minY, other.midY, other.maxY]
        }
        func best(_ values: [CGFloat], _ targets: [CGFloat]) -> (CGFloat, CGFloat)? {
            var result: (CGFloat, CGFloat)?
            for value in values {
                for target in targets where abs(target - value) <= distance {
                    if result.map({ abs(target - value) < abs($0.0) }) ?? true {
                        result = (target - value, target)
                    }
                }
            }
            return result
        }
        let x = best(xs, targetXs)
        let y = best(ys, targetYs)
        return (CGPoint(x: x?.0 ?? 0, y: y?.0 ?? 0), x.map { [$0.1] } ?? [], y.map { [$0.1] } ?? [])
    }

    /// The topmost object under `point`; lines and drawings count within `tolerance`.
    static func hitObject(at point: CGPoint, in document: BrowserEaselDocument, tolerance: CGFloat) -> String? {
        for object in document.objects.reversed() {
            let frame = object.frame
            switch object.content {
            case .shape(let shape) where shape.kind == .arrow || shape.kind == .freehand:
                let points = shape.kind == .arrow ? [shape.arrowStart, shape.arrowEnd] : shape.points
                let absolute = points.map { CGPoint(
                    x: frame.minX + $0.x * frame.width,
                    y: frame.minY + $0.y * frame.height,
                ) }
                if distance(from: point, toPolyline: absolute) <= tolerance { return object.id }
            default:
                if frame.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) { return object.id }
            }
        }
        return nil
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.infinity
        for (a, b) in zip(points, points.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            best = min(best, hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)))
        }
        return best
    }

    static func textHeight(_ text: BrowserEaselText, width: CGFloat) -> CGFloat {
        let font = text.font.font(style: text.style, scale: 1)
        let string = text.string.isEmpty ? BrowserStrings.easelTextPlaceholder : text.string
        let attributed = NSAttributedString(string: string, attributes: BrowserEaselRenderer.textAttributes(
            text,
            font: font,
            color: .black,
        ))
        let rect = attributed.boundingRect(
            with: CGSize(width: max(width - 2 * BrowserEaselRenderer.textInset, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
        )
        return max(ceil(rect.height) + 4, ceil(font.pointSize * text.font.lineHeight) + 4)
    }

    static func fitted(_ size: CGSize, maxWidth: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxWidth, height: maxWidth * 0.6) }
        let width = min(size.width, maxWidth)
        return CGSize(width: width, height: width * size.height / size.width)
    }

    private static func normalizedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, -frame.width + 20), BrowserEaselDocument.width - 20),
            y: max(frame.minY, 0),
            width: max(frame.width, 1),
            height: max(frame.height, 1),
        )
    }

    /// Takes a newer copy saved elsewhere, such as another window, without an undo step.
    func replaceDocument(_ newer: BrowserEaselDocument) {
        guard newer != document else { return }
        document = newer
        if let selectedObjectID, document.object(selectedObjectID) == nil {
            self.selectedObjectID = nil
        }
    }

    /// One undoable change; nothing is recorded when it changes nothing.
    @discardableResult func change(_ actionName: String, _ body: (inout BrowserEaselDocument) -> Void) -> Bool {
        var next = document
        body(&next)
        guard next != document else { return false }
        next.modifiedAt = now()
        commit(next, actionName: actionName)
        return true
    }

    // MARK: Objects

    @discardableResult func insert(_ object: BrowserEaselObject, select: Bool = true) -> String {
        change(BrowserStrings.easelUndoInsert) { $0.objects.append(object) }
        if select { selectedObjectID = object.id }
        return object.id
    }

    /// A shape dragged from one corner to the other; a click gives the default size.
    @discardableResult func insertShape(
        _ kind: BrowserEaselShapeKind,
        from start: CGPoint,
        to end: CGPoint,
        keepsSquare: Bool = false,
    ) -> String {
        var frame = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y),
        )
        var shape = BrowserEaselShape(kind: kind, color: kind.defaultColor)
        if kind == .arrow {
            if frame.width < 4, frame.height < 4 {
                frame = CGRect(x: start.x, y: start.y, width: Self.defaultShapeSize, height: 0)
                shape.arrowStart = CGPoint(x: 0, y: 0.5)
                shape.arrowEnd = CGPoint(x: 1, y: 0.5)
                frame = frame.insetBy(dx: 0, dy: -1)
            } else {
                shape.arrowStart = CGPoint(x: start.x <= end.x ? 0 : 1, y: start.y <= end.y ? 0 : 1)
                shape.arrowEnd = CGPoint(x: 1 - shape.arrowStart.x, y: 1 - shape.arrowStart.y)
                if frame.width < 1 { frame = frame.insetBy(dx: -0.5, dy: 0) }
                if frame.height < 1 { frame = frame.insetBy(dx: 0, dy: -0.5) }
            }
        } else if frame.width < 4, frame.height < 4 {
            let size = Self.defaultShapeSize
            frame = CGRect(x: start.x - size / 2, y: start.y - size / 2, width: size, height: size)
        } else if keepsSquare {
            let side = max(frame.width, frame.height)
            frame.size = CGSize(width: side, height: side)
            if end.x < start.x { frame.origin.x = start.x - side }
            if end.y < start.y { frame.origin.y = start.y - side }
        }
        return insert(BrowserEaselObject(frame: frame, content: .shape(shape)))
    }

    /// A pen stroke in Easel points; nil for a stroke of one point.
    @discardableResult func insertDrawing(_ points: [CGPoint]) -> String? {
        guard points.count > 1 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let frame = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        let normalized = points.map {
            CGPoint(x: ($0.x - frame.minX) / frame.width, y: ($0.y - frame.minY) / frame.height)
        }
        return insert(
            BrowserEaselObject(
                frame: frame,
                content: .shape(BrowserEaselShape(kind: .freehand, color: .black, points: normalized)),
            ),
            select: false,
        )
    }

    @discardableResult func insertText(at point: CGPoint, string: String = "") -> String {
        let font = BrowserEaselFont.clean
        let height = ceil(font.metrics(for: .body).size * font.lineHeight) + 4
        return insert(BrowserEaselObject(
            frame: CGRect(x: point.x, y: point.y - height / 2, width: 300, height: height),
            content: .text(BrowserEaselText(string: string)),
        ))
    }

    /// A picture `size` points large at most 400 wide, centered on `center`.
    @discardableResult func insertImage(fileName: String, size: CGSize, center: CGPoint) -> String {
        let fitted = Self.fitted(size, maxWidth: 400)
        return insert(BrowserEaselObject(
            frame: CGRect(
                x: center.x - fitted.width / 2,
                y: center.y - fitted.height / 2,
                width: fitted.width,
                height: fitted.height,
            ),
            content: .image(BrowserEaselImage(fileName: fileName)),
        ))
    }

    @discardableResult func insertCapture(_ capture: BrowserEaselCapture, size: CGSize, center: CGPoint) -> String {
        let fitted = Self.fitted(size, maxWidth: 500)
        return insert(BrowserEaselObject(
            frame: CGRect(
                x: center.x - fitted.width / 2,
                y: center.y - fitted.height / 2,
                width: fitted.width,
                height: fitted.height,
            ),
            content: .capture(capture),
        ))
    }

    func deleteSelection() {
        guard let id = selectedObjectID else { return }
        change(BrowserStrings.easelUndoDelete) { $0.objects.removeAll { $0.id == id } }
        selectedObjectID = nil
    }

    @discardableResult func duplicateSelection() -> String? {
        guard var copy = selectedObject else { return nil }
        copy.id = UUID().uuidString
        copy.frame = copy.frame.offsetBy(dx: 20, dy: 20)
        if case .text(var text) = copy.content {
            text.isTitle = false
            copy.content = .text(text)
        }
        return insert(copy)
    }

    func bringToFront(_ id: String) {
        change(BrowserStrings.easelUndoArrange) { document in
            guard let index = document.index(of: id) else { return }
            document.objects.append(document.objects.remove(at: index))
        }
    }

    func sendToBack(_ id: String) {
        change(BrowserStrings.easelUndoArrange) { document in
            guard let index = document.index(of: id) else { return }
            document.objects.insert(document.objects.remove(at: index), at: 0)
        }
    }

    func setFrame(_ frame: CGRect, of id: String, actionName: String = BrowserStrings.easelUndoMove) {
        change(actionName) { document in
            guard let index = document.index(of: id) else { return }
            document.objects[index].frame = Self.normalizedFrame(frame)
        }
    }

    /// Changes the object's content in one undo step.
    func updateContent(of id: String, actionName: String, _ body: (inout BrowserEaselContent) -> Void) {
        change(actionName) { document in
            guard let index = document.index(of: id) else { return }
            body(&document.objects[index].content)
        }
    }

    func setColor(_ color: BrowserEaselColor, of id: String) {
        updateContent(of: id, actionName: BrowserStrings.easelUndoColor) { content in
            guard case .shape(var shape) = content else { return }
            shape.color = color
            content = .shape(shape)
        }
    }

    func setText(_ string: String, of id: String) {
        updateContent(of: id, actionName: BrowserStrings.easelUndoTyping) { content in
            guard case .text(var text) = content else { return }
            text.string = string
            content = .text(text)
        }
    }

    /// The + and − of the text menu; false at the end of the range.
    @discardableResult func stepTextStyle(of id: String, larger: Bool) -> Bool {
        guard let text = document.object(id)?.content.text,
              let style = larger ? text.style.larger : text.style.smaller
        else { return false }
        updateContent(of: id, actionName: BrowserStrings.easelUndoTextStyle) { content in
            content = .text(BrowserEaselText(string: text.string, style: style, font: text.font, isTitle: text.isTitle))
        }
        fitTextHeight(of: id)
        return true
    }

    func cycleFont(of id: String) {
        guard let text = document.object(id)?.content.text else { return }
        updateContent(of: id, actionName: BrowserStrings.easelUndoTextStyle) { content in
            content = .text(BrowserEaselText(
                string: text.string,
                style: text.style,
                font: text.font.next,
                isTitle: text.isTitle,
            ))
        }
        fitTextHeight(of: id)
    }

    /// Makes the text the Easel's name, in place of the old title.
    func makeTitle(_ id: String) {
        change(BrowserStrings.easelUndoTitle) { document in
            for index in document.objects.indices {
                guard case .text(var text) = document.objects[index].content else { continue }
                text.isTitle = document.objects[index].id == id
                document.objects[index].content = .text(text)
            }
        }
    }

    func setLive(_ isLive: Bool, of id: String) {
        updateContent(of: id, actionName: BrowserStrings.easelUndoLive) { content in
            guard case .capture(var capture) = content else { return }
            capture.isLive = isLive
            content = .capture(capture)
        }
    }

    func setPalette(_ palette: BrowserEaselPalette) {
        change(BrowserStrings.easelUndoPalette) { $0.palette = palette }
    }

    func setUsesAlignmentGuides(_ uses: Bool) {
        change(BrowserStrings.easelUndoGuides) { $0.usesAlignmentGuides = uses }
    }

    /// A text box grows or shrinks to its lines; its width stays.
    func fitTextHeight(of id: String) {
        guard let object = document.object(id), let text = object.content.text else { return }
        let height = Self.textHeight(text, width: object.frame.width)
        guard abs(height - object.frame.height) > 0.5 else { return }
        var frame = object.frame
        frame.size.height = height
        replaceWithoutUndo(id: id, frame: frame)
    }

    private func replaceWithoutUndo(id: String, frame: CGRect) {
        guard let index = document.index(of: id) else { return }
        document.objects[index].frame = frame
        onChange?(document)
    }

    private func commit(_ next: BrowserEaselDocument, actionName: String) {
        let previous = document
        document = next
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.restore(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        onChange?(document)
    }

    private func restore(_ previous: BrowserEaselDocument, actionName: String) {
        let current = document
        document = previous
        if let selectedObjectID, previous.object(selectedObjectID) == nil {
            self.selectedObjectID = nil
        }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.restore(current, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        onChange?(document)
    }
}

// MARK: - BrowserEaselRenderer

/// Draws an Easel for the canvas, Library thumbnails, exports and tests.
@MainActor enum BrowserEaselRenderer {
    // MARK: Internal

    static let textInset: CGFloat = 5
    static let strokeWidth: CGFloat = 2.5
    static let cardRadius: CGFloat = 10

    static func background(isDark: Bool) -> NSColor {
        isDark
            ? NSColor(srgbRed: 14 / 255, green: 14 / 255, blue: 15 / 255, alpha: 1)
            : NSColor(srgbRed: 254 / 255, green: 253 / 255, blue: 254 / 255, alpha: 1)
    }

    static func textAttributes(
        _ text: BrowserEaselText,
        font: NSFont,
        color: NSColor,
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = text.style == .body ? .left : .center
        paragraph.lineHeightMultiple = text.font.lineHeight / 1.2
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// Draws in a flipped context where one Easel point is `scale` units.
    static func draw(
        _ document: BrowserEaselDocument,
        scale: CGFloat,
        isDark: Bool,
        store: BrowserEaselStore?,
        hiddenObjectID: String? = nil,
        placeholderObjectID: String? = nil,
    ) {
        for object in document.objects where object.id != hiddenObjectID {
            draw(
                object,
                document: document,
                scale: scale,
                isDark: isDark,
                store: store,
                showsPlaceholder: object.id == placeholderObjectID,
            )
        }
    }

    static func draw(
        _ object: BrowserEaselObject,
        document: BrowserEaselDocument,
        scale: CGFloat,
        isDark: Bool,
        store: BrowserEaselStore?,
        showsPlaceholder: Bool = false,
    ) {
        let rect = CGRect(
            x: object.frame.minX * scale,
            y: object.frame.minY * scale,
            width: object.frame.width * scale,
            height: object.frame.height * scale,
        )
        switch object.content {
        case .shape(let shape):
            drawShape(shape, in: rect, scale: scale, palette: document.palette, isDark: isDark)
        case .text(let text):
            let ink = BrowserEaselColor.black.color(palette: document.palette, isDark: isDark)
            let showsHint = text.string.isEmpty && showsPlaceholder
            guard !text.string.isEmpty || showsHint else { return }
            let font = text.font.font(style: text.style, scale: scale)
            let string = showsHint ? BrowserStrings.easelTextPlaceholder : text.string
            NSAttributedString(
                string: string,
                attributes: textAttributes(text, font: font, color: showsHint ? ink.withAlphaComponent(0.35) : ink),
            )
            .draw(
                with: rect.insetBy(dx: textInset * scale, dy: 0),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
            )
        case .image(let image):
            drawPicture(store?.image(named: image.fileName, easelID: document.id), in: rect, isDark: isDark, radius: 0)
        case .capture(let capture):
            let radius = cardRadius * scale
            drawPicture(
                store?.image(named: capture.fileName, easelID: document.id),
                in: rect,
                isDark: isDark,
                radius: radius,
            )
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            (isDark ? NSColor(white: 0.41, alpha: 1) : NSColor(white: 0, alpha: 0.1)).setStroke()
            border.lineWidth = 1
            border.stroke()
        }
    }

    static func drawShape(
        _ shape: BrowserEaselShape,
        in rect: CGRect,
        scale: CGFloat,
        palette: BrowserEaselPalette,
        isDark: Bool,
    ) {
        let color = shape.color.color(palette: palette, isDark: isDark)
        let stroke = shape.color == .white
            ? (isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1))
            : color
        let path = NSBezierPath()
        path.lineWidth = strokeWidth * scale
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        }
        switch shape.kind {
        case .rectangle:
            path.appendRect(rect)
            color.withAlphaComponent(0.75).setFill()
            path.fill()
        case .circle:
            path.appendOval(in: rect)
            color.withAlphaComponent(0.75).setFill()
            path.fill()
        case .freehand:
            guard let first = shape.points.first else { return }
            path.move(to: point(first))
            for unit in shape.points.dropFirst() {
                path.line(to: point(unit))
            }
        case .arrow:
            let start = point(shape.arrowStart), end = point(shape.arrowEnd)
            path.move(to: start)
            path.line(to: end)
            let dx = start.x - end.x, dy = start.y - end.y
            let length = max(hypot(dx, dy), 1)
            let flare = min(32 * scale, 0.3 * length) / length
            for angle in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                let nub = CGPoint(
                    x: end.x + (dx * cos(angle) - dy * sin(angle)) * flare,
                    y: end.y + (dx * sin(angle) + dy * cos(angle)) * flare,
                )
                path.move(to: nub)
                path.line(to: end)
            }
        }
        stroke.setStroke()
        path.stroke()
    }

    /// A picture filling the frame, cut to fit; a gray card while it loads.
    static func drawPicture(_ image: NSImage?, in rect: CGRect, isDark: Bool, radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(
                in: CGRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height,
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)],
            )
        } else {
            (isDark ? NSColor(white: 0.41, alpha: 1) : NSColor(white: 0, alpha: 0.1)).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The Easel as a picture `pixelWidth` wide, down to its last object, or
    /// the top `maximumAspect` widths of it.
    static func image(
        _ document: BrowserEaselDocument,
        pixelWidth: CGFloat,
        isDark: Bool,
        store: BrowserEaselStore?,
        maximumAspect: CGFloat? = nil,
    ) -> NSBitmapImageRep? {
        let scale = pixelWidth / BrowserEaselDocument.width
        var height = max(document.contentBottom + 40, 300)
        if let maximumAspect {
            height = min(height, BrowserEaselDocument.width * maximumAspect)
        }
        let pixelHeight = ceil(height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelWidth),
            pixelsHigh: Int(pixelHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.translateBy(x: 0, y: pixelHeight)
        cg.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.current = flipped
        background(isDark: isDark).setFill()
        CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
        draw(document, scale: scale, isDark: isDark, store: store)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A small picture of the Easel's top for the Library.
    static func thumbnail(_ document: BrowserEaselDocument, store: BrowserEaselStore?, isDark: Bool) -> NSImage? {
        guard let rep = image(document, pixelWidth: 200, isDark: isDark, store: store, maximumAspect: 0.625)
        else { return nil }
        let image = NSImage(size: CGSize(width: 100, height: CGFloat(rep.pixelsHigh) / 2))
        image.addRepresentation(rep)
        return image
    }
}
