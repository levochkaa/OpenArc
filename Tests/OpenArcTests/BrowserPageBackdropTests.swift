// BrowserPageBackdropTests.swift

import AppKit
import QuartzCore
import Testing

private let red = CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
private let blue = CGColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1)
private let pageSize = CGSize(width: 800, height: 600)

/// The layers a Chromium page view holds: a backing layer, a layer in the page's
/// background color and the layer that hosts the engine's frames.
private func pageLayer(background: CGColor?, hidden: Bool = false) -> CALayer {
    let root = CALayer()
    root.frame = CGRect(origin: .zero, size: pageSize)
    let container = CALayer()
    container.frame = root.bounds
    let fill = CALayer()
    fill.frame = root.bounds
    fill.backgroundColor = background
    fill.isHidden = hidden
    let content = CALayer()
    content.frame = root.bounds
    fill.addSublayer(content)
    container.addSublayer(fill)
    root.addSublayer(container)
    return root
}

private func components(_ color: CGColor?) -> [CGFloat]? {
    color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components
}

@Test func pageBackdropFindsThePageBackgroundLayer() {
    #expect(components(BrowserPageBackdropColor.pageColor(in: pageLayer(background: red), size: pageSize))
        == components(red))
}

@Test func pageBackdropIgnoresMissingHiddenOrTransparentBackgrounds() {
    #expect(BrowserPageBackdropColor.pageColor(in: pageLayer(background: nil), size: pageSize) == nil)
    #expect(BrowserPageBackdropColor.pageColor(in: pageLayer(background: red, hidden: true), size: pageSize) == nil)
    let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
    #expect(BrowserPageBackdropColor.pageColor(in: pageLayer(background: clear), size: pageSize) == nil)
}

@Test func pageBackdropIgnoresLayersSmallerThanThePage() {
    let root = CALayer()
    root.frame = CGRect(origin: .zero, size: pageSize)
    let scroller = CALayer()
    scroller.frame = CGRect(x: 785, y: 0, width: 15, height: 600)
    scroller.backgroundColor = red
    root.addSublayer(scroller)

    #expect(BrowserPageBackdropColor.pageColor(in: root, size: pageSize) == nil)
}

@Test func pageBackdropPrefersTheTabColorThenTheSiteThenTheDefault() {
    #expect(BrowserPageBackdropColor.color(tabColor: red, siteColor: blue, darkAppearance: false) === red)
    #expect(BrowserPageBackdropColor.color(tabColor: nil, siteColor: blue, darkAppearance: true) === blue)
    #expect(components(BrowserPageBackdropColor.color(tabColor: nil, siteColor: nil, darkAppearance: false))
        == [1, 1, 1, 1])
    // A dark appearance never starts from white.
    let dark = components(BrowserPageBackdropColor.color(tabColor: nil, siteColor: nil, darkAppearance: true))
    #expect((dark?[0] ?? 1) < 0.2)
}

@Test func pageBackdropKeysSitesByHost() {
    #expect(BrowserPageBackdropColor.siteKey(forURLString: "https://GitHub.com/openarc?tab=1") == "github.com")
    #expect(BrowserPageBackdropColor.siteKey(forURLString: "http://127.0.0.1:8765/red") == "127.0.0.1")
    #expect(BrowserPageBackdropColor.siteKey(forURLString: "about:blank") == nil)
    #expect(BrowserPageBackdropColor.siteKey(forURLString: "openarc://settings") == nil)
    #expect(BrowserPageBackdropColor.siteKey(forURLString: nil) == nil)
}

@MainActor private func pageView(background: CGColor?) -> NSView {
    let view = NSView(frame: CGRect(origin: .zero, size: pageSize))
    view.wantsLayer = true
    view.layer?.addSublayer(pageLayer(background: background))
    return view
}

@Test
@MainActor func pageBackdropSitsBetweenTheShownPageAndThePagesKeptBelow() {
    let host = NSView(frame: CGRect(origin: .zero, size: pageSize))
    let warm = pageView(background: blue)
    let shown = pageView(background: nil)
    host.addSubview(warm)
    host.addSubview(shown)
    let backdrop = BrowserPageBackdrop()

    backdrop.show(below: shown, in: host, tabColor: NSColor(cgColor: red), urlString: "https://example.com")

    #expect(host.subviews.count == 3)
    #expect(host.subviews.first === warm)
    #expect(host.subviews.last === shown)
    let fill = host.subviews[1]
    #expect(!fill.isHidden)
    #expect(fill.frame == shown.frame)
    #expect(fill.hitTest(NSPoint(x: 10, y: 10)) == nil)
    #expect(components(fill.layer?.backgroundColor) == components(red))

    // Shown again for the same page, it stays in place.
    backdrop.show(below: shown, in: host, tabColor: nil, urlString: nil)
    #expect(host.subviews.count == 3)
    #expect(host.subviews[1] === fill)

    backdrop.hide()
    #expect(fill.isHidden)
}

@Test
@MainActor func pageBackdropUsesTheSiteColorForATabWithoutOne() throws {
    let host = NSView(frame: CGRect(origin: .zero, size: pageSize))
    let seen = pageView(background: red)
    let fresh = pageView(background: nil)
    host.addSubview(seen)
    host.addSubview(fresh)
    let backdrop = BrowserPageBackdrop()

    let remembered = backdrop.rememberColor(ofPageView: seen, urlString: "https://example.com/a")
    #expect(components(remembered?.cgColor) == components(red))
    #expect(backdrop.rememberColor(ofPageView: fresh, urlString: "https://example.com/b") == nil)

    backdrop.show(below: fresh, in: host, tabColor: nil, urlString: "https://example.com/b")
    let fill = try #require(host.subviews.first { $0 !== seen && $0 !== fresh })
    #expect(components(fill.layer?.backgroundColor) == components(red))
}
