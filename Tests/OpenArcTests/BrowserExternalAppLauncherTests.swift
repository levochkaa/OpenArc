// BrowserExternalAppLauncherTests.swift

import AppKit
import Testing

@MainActor struct BrowserExternalAppLauncherTests {
    // MARK: Private

    @MainActor private final class Harness {
        var opened = [URL]()
        var time = Date(timeIntervalSince1970: 0)
        private(set) var launcher: BrowserExternalAppLauncher!

        init() {
            self.launcher = BrowserExternalAppLauncher(
                appURL: { url in
                    switch url.scheme {
                    case "slack": URL(fileURLWithPath: "/Applications/Slack.app")
                    case "mailto": URL(fileURLWithPath: "/System/Applications/Mail.app")
                    case "tb": Bundle.main.bundleURL
                    case "arc": URL(fileURLWithPath: "/Applications/Another Browser.app")
                    default: nil
                    }
                },
                open: { [unowned self] in opened.append($0) },
                now: { [unowned self] in time },
            )
        }
    }

    // MARK: Internal

    @Test func onlyLinksThatBelongToAnotherAppAreHandedOver() {
        let h = Harness()
        #expect(h.launcher.handles("slack://channel?team=T1&id=C1"))
        #expect(h.launcher.handles("mailto:someone@example.com"))
        #expect(!h.launcher.handles("https://example.slack.com/archives/C1"), "Web pages load in the browser")
        #expect(!h.launcher.handles("arc://settings"), "Browser addresses stay in the browser")
        #expect(!h.launcher.handles("unknown://thing"), "No app opens it, so the page shows the error")
        #expect(!h.launcher.handles("tb://open"), "The browser's own scheme")
    }

    @Test func anAppLinkOpensItsAppAtOnceButNotInALoop() {
        let h = Harness()
        h.launcher.open("slack://channel?team=T1&id=C1", in: nil)
        #expect(h.opened.map(\.absoluteString) == ["slack://channel?team=T1&id=C1"])

        h.time += 0.2
        h.launcher.open("slack://again", in: nil)
        #expect(h.opened.count == 1, "A page sending links in a loop opens one a second")

        h.time += 1
        h.launcher.open("slack://later", in: nil)
        #expect(h.opened.count == 2)

        h.launcher.open("https://example.com", in: nil)
        #expect(h.opened.count == 2, "A web page is not handed to an app")
    }
}
