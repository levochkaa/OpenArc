// BrowserFaviconNSView.swift

import AppKit
import Combine

final class BrowserFaviconNSView: NSImageView {
    /// What stands in for a page without an icon.
    enum Fallback {
        case globe
        /// A plain rounded square, as in the sidebar.
        case square
    }

    /// 14 pt with 3 pt corners inside a 16 pt icon, tinted by the view.
    static let squareImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let globeImage = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)

    /// Rows refresh their icon often; the same image or tint leaves the view as it is.
    override var image: NSImage? {
        get { super.image }
        set {
            guard newValue !== super.image else { return }
            super.image = newValue
        }
    }

    override var contentTintColor: NSColor? {
        get { super.contentTintColor }
        set {
            guard newValue != super.contentTintColor else { return }
            super.contentTintColor = newValue
        }
    }

    // MARK: Internal

    var fallback = Fallback.globe {
        didSet { if fallback != oldValue { refreshImage() } }
    }

    // MARK: Private

    private let cache: BrowserFaviconCache
    private var url: URL?
    private var pageURLString: String?
    /// Favicons arriving for other pages ask once per run loop pass.
    private var cacheRefresh: BrowserCoalescedRefresh?
    private var loadTask: Task<Void, Never>?

    init(cache: BrowserFaviconCache = .shared) {
        self.cache = cache
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(false)
        let cacheRefresh = BrowserCoalescedRefresh { [weak self] in self?.refreshImage() }
        cacheRefresh.observe([cache.objectWillChange.eraseToAnyPublisher()])
        self.cacheRefresh = cacheRefresh
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    isolated deinit { loadTask?.cancel() }

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

    private func refreshImage() {
        if let symbol = BrowserFaviconFallbackStyle.webUISymbol(forPageURLString: pageURLString) {
            image = BrowserIconImage.image(named: symbol, pointSize: 13, weight: .semibold)
            contentTintColor = BrowserChromeColors.internalPageIcon
        } else if BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString) == .chromiumWebUI {
            image = NSImage(named: "ChromiumWebUIFavicon")
            contentTintColor = nil
        } else if let cached = cache.image(for: url) {
            image = cached
            contentTintColor = nil
        } else if fallback == .square {
            image = Self.squareImage
            contentTintColor = NSColor.labelColor.withAlphaComponent(0.13)
        } else {
            image = Self.globeImage
            contentTintColor = BrowserChromeColors.secondaryText
        }
    }
}
