import AppKit
import Testing

@Suite(.serialized)
@MainActor struct BrowserNativeAnimationTests {
    @Test func springPreservesOvershootAndEasingPreservesEndpoints() {
        let press = BrowserNativeAnimation.Curve.press
        #expect(press.value(at: 0) == 0)
        #expect(press.value(at: 0.13) > 1)
        #expect(press.value(at: press.duration) == 1)
        let sidebar = BrowserNativeAnimation.Curve.sidebar
        #expect(abs(sidebar.value(at: 0.09) - 0.5) < 0.0001)
        #expect(sidebar.value(at: 0.045) < 0.25)
        #expect(sidebar.value(at: 0.135) > 0.75)
    }

    @Test func synchronousFramesKeepPageAndSidebarTogether() {
        let openSidebar = CGRect(x: 0, y: 0, width: 240, height: 700)
        let closedSidebar = openSidebar.offsetBy(dx: -240, dy: 0)
        let openPage = CGRect(x: 240, y: 8, width: 752, height: 684)
        let closedPage = CGRect(x: 8, y: 8, width: 984, height: 684)
        for progress in [0.1, 0.5, 0.9] {
            let sidebar = BrowserNativeAnimation.interpolate(openSidebar, closedSidebar, progress)
            let page = BrowserNativeAnimation.interpolate(openPage, closedPage, progress)
            #expect(abs(page.minX - sidebar.maxX - 8 * progress) < 0.001)
            #expect(sidebar.width == 240)
            #expect(page.maxX == 992)
        }
    }

    @Test func replacementViewReceivesTheSameVisibilityTarget() {
        let first = NSView()
        let replacement = NSView()
        let animation = BrowserNativeVisibilityAnimation()
        animation.setVisible(false, view: first, curve: .sidebar)
        animation.setVisible(false, view: replacement, curve: .sidebar)
        #expect(first.isHidden)
        #expect(replacement.isHidden)
        #expect(replacement.alphaValue == 0)
    }

    @Test func supersededVisibilityCannotHideReopenedControl() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = try NSView(frame: #require(window.contentView?.bounds))
        window.contentView?.addSubview(view)
        let animation = BrowserNativeVisibilityAnimation()
        animation.setVisible(true, view: view, curve: .hover)
        animation.setVisible(false, view: view, curve: .hover)
        animation.setVisible(true, view: view, curve: .hover)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!view.isHidden)
        #expect(view.alphaValue == 1)
    }
}
