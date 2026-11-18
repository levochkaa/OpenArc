// BrowserDownloadFileActions.swift

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - BrowserDownloadFile

/// A finished download as the tray and the Library act on it: its kind decides
/// the words in its menu.
struct BrowserDownloadFile: Equatable {
    let url: URL

    var isImage: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    var copyTitle: String {
        isImage ? BrowserStrings.downloadsCopyImage : BrowserStrings.downloadsCopyFile
    }

    var openTitle: String {
        isImage ? BrowserStrings.downloadsOpenImage : BrowserStrings.downloadsOpen
    }

    /// "Open in Preview", or plain "Open" when no app claims the file.
    static func openInTitle(applicationName: String?) -> String {
        guard let applicationName, !applicationName.isEmpty else { return BrowserStrings.downloadsOpen }
        return BrowserStrings.downloadsOpenIn(applicationName)
    }
}

// MARK: - BrowserDownloadFileMenu

/// The menus of a finished download. The tray's starts with sharing and names the
/// app that opens the file; the Library's starts with Open and can drop the row.
@MainActor enum BrowserDownloadFileMenu {
    enum Item: Equatable {
        case open
        case openIn(String)
        case copy
        case share(String)
        case showInFinder
        case removeFromList
        case moveToTrash
        case separator
    }

    /// What the menu lists, so tests can read it without a workspace.
    static func items(
        for file: BrowserDownloadFile,
        inTray: Bool,
        applicationName: String?,
        shareTitles: [String],
        canRemoveFromList: Bool,
    ) -> [Item] {
        if inTray {
            var items: [Item] = [.copy, .separator]
            if !shareTitles.isEmpty {
                items += shareTitles.map(Item.share) + [.separator]
            }
            items += [.openIn(BrowserDownloadFile.openInTitle(applicationName: applicationName)), .showInFinder]
            items += [.separator, .moveToTrash]
            return items
        }
        var items: [Item] = [.open, .copy, .showInFinder, .separator]
        if canRemoveFromList {
            items.append(.removeFromList)
        }
        items.append(.moveToTrash)
        return items
    }

    static func menu(
        for file: BrowserDownloadFile,
        inTray: Bool,
        workspace: NSWorkspace = .shared,
        onRemoveFromList: (() -> Void)? = nil,
        onTrashed: (@MainActor @Sendable () -> Void)? = nil,
    ) -> NSMenu {
        let menu = BrowserNativeMenus.menu()
        let url = file.url
        let services = inTray ? shareServices(for: url) : []
        let application = workspace.urlForApplication(toOpen: url)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { ($0 as NSString).deletingPathExtension }
        let items = items(
            for: file,
            inTray: inTray,
            applicationName: application,
            shareTitles: services.map(\.menuItemTitle),
            canRemoveFromList: onRemoveFromList != nil,
        )
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .open:
                BrowserNativeMenus.add(file.openTitle, to: menu) { workspace.open(url) }
            case .openIn(let title):
                BrowserNativeMenus.add(title, to: menu) { workspace.open(url) }
            case .copy:
                BrowserNativeMenus.add(file.copyTitle, to: menu) { copy(file, to: .general) }
            case .share(let title):
                guard let service = services.first(where: { $0.menuItemTitle == title }) else { continue }
                let entry = BrowserNativeMenus.add(title, to: menu) { service.perform(withItems: [url]) }
                entry.image = service.image
            case .showInFinder:
                BrowserNativeMenus.add(BrowserStrings.libraryRevealInFinder, to: menu) {
                    workspace.activateFileViewerSelecting([url])
                }
            case .removeFromList:
                BrowserNativeMenus.add(BrowserStrings.downloadsRemoveFromList, to: menu) { onRemoveFromList?() }
            case .moveToTrash:
                BrowserNativeMenus.add(BrowserStrings.downloadsMoveToTrash, to: menu) {
                    workspace.recycle([url]) { _, error in
                        guard error == nil, let onTrashed else { return }
                        Task { @MainActor in onTrashed() }
                    }
                }
            }
        }
        return menu
    }

    /// The file itself, and for a picture its image too, so both Finder and editors can paste it.
    static func copy(_ file: BrowserDownloadFile, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [file.url as NSURL]
        if file.isImage, let image = NSImage(contentsOf: file.url) {
            objects.append(image)
        }
        pasteboard.writeObjects(objects)
    }

    /// Messages and AirDrop, the ways to send a file straight from the tray.
    private static func shareServices(for url: URL) -> [NSSharingService] {
        [NSSharingService.Name.composeMessage, .sendViaAirDrop]
            .compactMap(NSSharingService.init(named:))
            .filter { $0.canPerform(withItems: [url]) }
    }
}

// MARK: - BrowserDownloadFilePromiseProvider

/// A dragged download: a promise that writes a copy where it lands, plus the
/// file's address for apps that take files but not promises.
final class BrowserDownloadFilePromiseProvider: NSFilePromiseProvider {
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.fileURL]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL {
            return (userInfo as? URL)?.absoluteString
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

// MARK: - BrowserDownloadFileDrag

/// Drags a finished download out of the tray or the Library. Wherever it lands
/// gets a copy; the file stays in the download folder.
@MainActor final class BrowserDownloadFileDrag: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    static let shared = BrowserDownloadFileDrag()

    /// Copies run off the main thread; the queue is only handed to AppKit.
    private nonisolated static let copyQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var onEnd: (() -> Void)?

    static func provider(for url: URL) -> BrowserDownloadFilePromiseProvider {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let provider = BrowserDownloadFilePromiseProvider(fileType: type.identifier, delegate: shared)
        provider.userInfo = url
        return provider
    }

    /// Starts the drag with `view` itself as the image. Returns false when no event can start one.
    @discardableResult func begin(
        fileURL url: URL,
        from view: NSView,
        event: NSEvent? = NSApp.currentEvent,
        onEnd: @escaping () -> Void = {},
    ) -> Bool {
        guard let event, FileManager.default.fileExists(atPath: url.path) else { return false }
        let item = NSDraggingItem(pasteboardWriter: Self.provider(for: url))
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        item.setDraggingFrame(view.bounds, contents: image)
        self.onEnd = onEnd
        let session = view.beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    // MARK: NSDraggingSource

    nonisolated func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext)
        -> NSDragOperation
    {
        .copy
    }

    nonisolated func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
        MainActor.assumeIsolated {
            onEnd?()
            onEnd = nil
        }
    }

    // MARK: NSFilePromiseProviderDelegate

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType _: String) -> String {
        (provider.userInfo as? URL)?.lastPathComponent ?? BrowserStrings.downloadsDefaultFileName
    }

    nonisolated func filePromiseProvider(
        _ provider: NSFilePromiseProvider,
        writePromiseTo destination: URL,
        completionHandler: @escaping (Error?) -> Void,
    ) {
        guard let source = provider.userInfo as? URL else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for _: NSFilePromiseProvider) -> OperationQueue {
        Self.copyQueue
    }
}

// MARK: - BrowserDownloadThumbnail

/// Thumbnails of downloaded files, made off the main thread and kept while the app runs.
/// Pictures go through `BrowserImageThumbnailer`; other files ask QuickLook, and keep
/// their icon when it has nothing.
@MainActor enum BrowserDownloadThumbnail {
    private struct Box: @unchecked Sendable {
        let image: NSImage?
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: key(url))
    }

    static func load(_ url: URL, side: CGFloat, scale: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        if let image = cached(url) {
            completion(image)
            return
        }
        let key = key(url) as String
        let deliver: @Sendable (Box) -> Void = { box in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let image = box.image else { return }
                    cache.setObject(image, forKey: key as NSString)
                    completion(image)
                }
            }
        }
        if BrowserDownloadFile(url: url).isImage {
            let pixels = side * scale
            DispatchQueue.global(qos: .userInitiated).async {
                deliver(Box(image: BrowserImageThumbnailer.image(contentsOf: url, maximumPixelSize: pixels)))
            }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail,
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            deliver(Box(image: thumbnail?.nsImage))
        }
    }

    /// A file replaced under the same name gets a new thumbnail.
    private static func key(_ url: URL) -> NSString {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(date?.timeIntervalSince1970 ?? 0)" as NSString
    }
}
