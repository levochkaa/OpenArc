// BrowserPageBackdrop.swift

import AppKit
import QuartzCore

// MARK: - BrowserPageBackdropColor

/// The color a tab's page area shows from the moment it is selected until the page draws
/// itself. A page view stays transparent until its engine delivers a frame, which can take
/// a second after the tab was hidden; without a fill, the pages kept drawn below it would
/// show through in its place.
enum BrowserPageBackdropColor {
    // MARK: Private

    private static let lightDefault = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let darkDefault = CGColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)

    // MARK: Internal

    /// Chromium's page background before a page draws: white, or a dark gray when the
    /// page follows a dark appearance.
    static func defaultColor(darkAppearance: Bool) -> CGColor {
        darkAppearance ? darkDefault : lightDefault
    }

    /// The color the page area takes: the tab's own page color, else one remembered for
    /// its site, else the default page background.
    static func color(tabColor: CGColor?, siteColor: CGColor?, darkAppearance: Bool) -> CGColor {
        tabColor ?? siteColor ?? defaultColor(darkAppearance: darkAppearance)
    }

    /// The page's background as its engine paints it: the first visible, opaque layer
    /// color that covers the page view, searched a few levels deep. Nil before the page
    /// set one.
    static func pageColor(in layer: CALayer, size: CGSize, depth: Int = 6) -> CGColor? {
        guard !layer.isHidden, layer.opacity > 0 else { return nil }
        if let color = layer.backgroundColor, isOpaque(color), covers(layer.bounds.size, size) {
            return color
        }
        guard depth > 0 else { return nil }
        for sublayer in layer.sublayers ?? [] {
            if let color = pageColor(in: sublayer, size: size, depth: depth - 1) {
                return color
            }
        }
        return nil
    }

    /// Pages of one site usually share a background; the host's lowercased name keys it.
    static func siteKey(forURLString urlString: String?) -> String? {
        guard let urlString, let components = URLComponents(string: urlString),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        return host
    }

    private static func isOpaque(_ color: CGColor) -> Bool {
        color.alpha >= 0.999
    }

    /// A layer of the whole page, not a scroll bar or a corner of it.
    private static func covers(_ layerSize: CGSize, _ size: CGSize) -> Bool {
        layerSize.width >= size.width * 0.9 && layerSize.height >= size.height * 0.9
    }
}

// MARK: - BrowserPageBackdrop

/// A fill under the shown page, above the pages kept drawn for a quick switch, in the
/// page's own background color. Wherever the page has not drawn yet, after a switch or
/// while the window grows, this color shows instead of another tab's page.
@MainActor @objc(BrowserPageBackdrop) final class BrowserPageBackdrop: NSObject {
    // MARK: Private

    private static let maximumSiteCount = 256

    private let view = BrowserPageBackdropView()
    private var siteColors = [String: CGColor]()

    // MARK: Internal

    /// Remembers the page color of a page on screen for its site and returns it, so the
    /// tab keeps it for its next switch. Nil before the page painted a background.
    @objc(rememberColorOfPageView:URLString:)
    func rememberColor(ofPageView pageView: NSView, urlString: String?) -> NSColor? {
        guard !pageView.isHidden, let layer = pageView.layer, pageView.bounds.width > 0,
              pageView.bounds.height > 0,
              let color = BrowserPageBackdropColor.pageColor(in: layer, size: pageView.bounds.size)
        else { return nil }
        if let site = BrowserPageBackdropColor.siteKey(forURLString: urlString) {
            if siteColors.count >= Self.maximumSiteCount, siteColors[site] == nil {
                siteColors.removeAll()
            }
            siteColors[site] = color
        }
        return NSColor(cgColor: color)
    }

    /// Puts the fill right below the page view, over the page's frame, in the tab's color.
    @objc(showBelowPageView:inHostView:tabColor:URLString:)
    func show(below pageView: NSView, in hostView: NSView, tabColor: NSColor?, urlString: String?) {
        let siteColor = BrowserPageBackdropColor.siteKey(forURLString: urlString).flatMap { siteColors[$0] }
        let color = BrowserPageBackdropColor.color(
            tabColor: tabColor?.cgColor,
            siteColor: siteColor,
            darkAppearance: hostView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.backgroundColor = color
        let subviews = hostView.subviews
        if let pageIndex = subviews.firstIndex(where: { $0 === pageView }),
           pageIndex == 0 || subviews[pageIndex - 1] !== view
        {
            hostView.addSubview(view, positioned: .below, relativeTo: pageView)
        }
        if view.frame != pageView.frame {
            view.frame = pageView.frame
        }
        view.isHidden = false
        CATransaction.commit()
    }

    @objc func hide() {
        view.isHidden = true
    }
}

// MARK: - BrowserPageBackdropView

/// A plain fill: no events, no accessibility element, no implicit animations.
private final class BrowserPageBackdropView: NSView {
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        autoresizingMask = [.width, .height]
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}
