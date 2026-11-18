// BrowserCaptureCardPresenter.swift

import AppKit
import UniformTypeIdentifiers

// MARK: - BrowserCaptureRequest

/// A finished capture on its way to the card.
struct BrowserCaptureRequest {
    enum Placement: Equatable {
        /// Where it was outlined, as fractions of the page view, y downward.
        case outlined(CGRect)
        /// No place on the page: centered with the menu.
        case centered
    }

    let png: Data
    let kind: BrowserCapture.Kind
    let placement: Placement
    /// A picture of the whole page view for the gray page behind the card.
    let pagePNG: Data?
    let pageURL: String?
    let title: String?
    let tabID: String?
}

// MARK: - BrowserCaptureCardPresenter

/// Runs the capture card's menu: the Library, the clipboard, a file, Messages,
/// Preview's Markup, a new outline and a new Easel.
@MainActor final class BrowserCaptureCardPresenter: NSObject, NSSharingServiceDelegate {
    // MARK: Internal

    let request: BrowserCaptureRequest
    let card: BrowserCaptureCardView
    var onClose: () -> Void = {}

    // MARK: Private

    private weak var model: BrowserChromeModel?
    private var png: Data
    private var savedCapture: BrowserCapture?
    private var fileURL: URL?
    private var editWatcher: DispatchSourceFileSystemObject?

    init(request: BrowserCaptureRequest, card: BrowserCaptureCardView, model: BrowserChromeModel) {
        self.request = request
        self.png = request.png
        self.card = card
        self.model = model
        super.init()
    }

    isolated deinit {
        editWatcher?.cancel()
    }

    /// The Send To menu for a capture in this window.
    static func menu(for model: BrowserChromeModel) -> BrowserCaptureCardMenu {
        var menu = BrowserCaptureCardMenu()
        menu.canSaveToLibrary = !model.isIncognito && BrowserCaptureStore.shared != nil
        menu.canCreateEasel = model.onNewEaselFromCapture != nil
        return menu
    }

    func perform(_ action: BrowserCaptureCardAction) {
        switch action {
        case .toggleLibrary: toggleLibrary()
        case .copy: copyPicture()
        case .save: save()
        case .sendMessage: sendMessage()
        case .edit: edit()
        case .retake:
            onClose()
            model?.beginAreaCapture()
        case .newEasel:
            guard let create = model?.onNewEaselFromCapture else { return }
            onClose()
            create(png, request.pageURL)
        }
    }

    /// Stops following an edit in Preview once the card closes.
    func stopFollowingEdits() {
        editWatcher?.cancel()
        editWatcher = nil
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(
        _: NSSharingService,
        sourceWindowForShareItems _: [Any],
        sharingContentScope _: UnsafeMutablePointer<NSSharingService.SharingContentScope>,
    ) -> NSWindow? {
        card.window
    }

    /// A file of the picture for Messages and Preview, one folder per card.
    private func temporaryFile() -> URL? {
        if let fileURL {
            return fileURL
        }
        let directory = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("OpenArc Captures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(BrowserStrings.captureFileName + ".png", isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        fileURL = url
        return url
    }

    private func toggleLibrary() {
        guard let store = BrowserCaptureStore.shared else { return }
        if let savedCapture {
            store.delete(savedCapture)
            self.savedCapture = nil
        } else {
            savedCapture = store.save(png: png, kind: request.kind, pageURL: request.pageURL, title: request.title)
        }
        card.setSavedToLibrary(savedCapture != nil)
    }

    private func copyPicture() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        onClose()
        NotificationCenter.default.post(name: BrowserCaptureToastView.didCopyNotification, object: png)
    }

    private func save() {
        guard let window = card.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = BrowserStrings.captureFileName
        let png = png
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url, options: .atomic)
            MainActor.assumeIsolated { self?.onClose() }
        }
    }

    private func sendMessage() {
        guard let url = temporaryFile(), let service = NSSharingService(named: .composeMessage) else { return }
        service.delegate = self
        service.perform(withItems: [url])
        onClose()
    }

    /// The picture opens in Preview for Markup; what Preview saves comes back
    /// into the card, and into the Library when it is saved there.
    private func edit() {
        guard let url = temporaryFile() else { return }
        followEdits(of: url)
        let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        if let preview {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Preview saves by replacing the file, so each change starts a new watch.
    private func followEdits(of url: URL) {
        editWatcher?.cancel()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main,
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.editWatcher === source else { return }
                let replaced = !source.data.isDisjoint(with: [.rename, .delete])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.editWatcher === source else { return }
                        if let data = try? Data(contentsOf: url) {
                            self.receiveEdited(data)
                        }
                        if replaced {
                            self.followEdits(of: url)
                        }
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        editWatcher = source
        source.resume()
    }

    private func receiveEdited(_ data: Data) {
        guard data != png, let image = BrowserCaptureImaging.cgImage(png: data),
              let edited = BrowserCaptureImaging.png(image)
        else { return }
        png = data
        card.replacePicture(NSImage(cgImage: image, size: .zero))
        if let savedCapture {
            BrowserCaptureStore.shared?.replacePNG(edited, of: savedCapture)
        }
    }
}
