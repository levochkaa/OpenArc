import AppKit
import Combine

final class BrowserFaviconNSView: NSImageView {
    // MARK: Lifecycle

    init(cache: BrowserFaviconCache = .shared) {
        self.cache = cache
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(false)
        self.observation = cache.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.refreshImage() }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { loadTask?.cancel() }

    // MARK: Internal

    func update(url: URL?, pageURLString: String?) {
        let changed = self.url != url || self.pageURLString != pageURLString
        self.url = url
        self.pageURLString = pageURLString
        refreshImage()
        guard changed else { return }
        loadTask?.cancel()
        guard BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) != .chromiumWebUI else { return }
        loadTask = Task { [weak self, cache] in
            await cache.loadImageIfNeeded(from: url)
            guard !Task.isCancelled else { return }
            self?.refreshImage()
        }
    }

    // MARK: Private

    private let cache: BrowserFaviconCache
    private var url: URL?
    private var pageURLString: String?
    private var observation: AnyCancellable?
    private var loadTask: Task<Void, Never>?

    private func refreshImage() {
        if BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) == .chromiumWebUI {
            image = NSImage(named: "ChromiumWebUIFavicon")
            contentTintColor = nil
        } else if let cached = cache.image(for: url) {
            image = cached
            contentTintColor = nil
        } else {
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            contentTintColor = BrowserChromeColors.secondaryText
        }
    }
}
