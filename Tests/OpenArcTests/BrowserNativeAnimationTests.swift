// BrowserNativeAnimationTests.swift

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
        #expect(sidebar.duration == 0.08)
        #expect(sidebar.value(at: 0.04) > 0.5, "Starts fast and eases out")
        #expect(sidebar.value(at: 0.08) == 1)
        let slide = BrowserNativeAnimation.Curve.spaceSlide
        #expect(abs(slide.value(at: 1.0 / 60) - 0.216) < 0.05)
        #expect(abs(slide.value(at: 4.0 / 60) - 0.76) < 0.05)
        let settle = BrowserNativeAnimation.Curve.spaceSelect
        #expect((0..<40).map { settle.value(at: Double($0) / 120) }.allSatisfy { $0 <= 1.0001 }, "No overshoot")
    }

    @Test func springsMatchTheirStiffnessAndDamping() {
        // Springs have unit mass: stiffness = ω², damping = 2ζω.
        for (curve, stiffness, damping) in [
            (BrowserNativeAnimation.Curve.rowPress, 986.96, 31.42),
            (.floatingSidebar, 1366.02, 59.13),
        ] {
            guard case .spring(let response, let ratio) = curve else {
                Issue.record("expected a spring")
                continue
            }
            let omega = 2 * Double.pi / response
            #expect(abs(omega * omega - stiffness) / stiffness < 0.002)
            #expect(abs(2 * ratio * omega - damping) / damping < 0.002)
        }
        // The row press bounces visibly; the floating sidebar barely overshoots.
        let rowPeak = stride(from: 0.0, to: 0.2, by: 0.005).map(BrowserNativeAnimation.Curve.rowPress.value).max() ?? 0
        let sidebarPeak = stride(from: 0.0, to: 0.2, by: 0.005)
            .map(BrowserNativeAnimation.Curve.floatingSidebar.value)
            .max() ?? 0
        #expect(rowPeak > 1.1)
        #expect(sidebarPeak > 1 && sidebarPeak < 1.03)
        #expect(BrowserNativeAnimation.Curve.hover.duration == 0.1, "Hover fills")
        #expect(BrowserNativeAnimation.Curve.appearance.duration == 0.15, "Element appearance")
        #expect(BrowserNativeSidebarRowNSView().pressCurve.duration == BrowserNativeAnimation.Curve.rowPress.duration)
        #expect(BrowserNativePressableView().pressCurve.duration == BrowserNativeAnimation.Curve.press.duration)
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
            defer: false,
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
