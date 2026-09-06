import AppKit
import SwiftUI

/// Temporary mounting adapter; toolbar state and layout live in AppKit.
struct BrowserSiteToolbar: NSViewRepresentable {
    let model: BrowserChromeModel
    let onURLButtonFrameChange: (CGRect?) -> Void

    static func dismantleNSView(_ view: BrowserSiteControlsNSView, coordinator _: ()) {
        view.closePopovers()
        view.onURLFrameChange(nil)
    }

    func makeNSView(context _: Context) -> BrowserSiteControlsNSView {
        let view = BrowserSiteControlsNSView(model: model, mode: .toolbar)
        view.onURLFrameChange = onURLButtonFrameChange
        return view
    }

    func updateNSView(_ view: BrowserSiteControlsNSView, context _: Context) {
        view.onURLFrameChange = onURLButtonFrameChange
        view.refresh()
    }
}
