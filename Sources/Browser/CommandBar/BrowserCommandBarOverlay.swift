import AppKit
import SwiftUI

/// Temporary window-shell adapter. The command model and AppKit view own behavior and rendering.
struct BrowserCommandBarOverlay: NSViewRepresentable {
    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let model: BrowserCommandBarModel
    let blockedLeadingInset: CGFloat
    let style: BrowserCommandBarOverlayStyle
    let faviconCandidate: BrowserCommandBarFaviconCandidate?

    func makeNSView(context: Context) -> BrowserCommandBarNSView {
        let view = BrowserCommandBarNSView(model: model, faviconCache: faviconCache)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserCommandBarNSView, context _: Context) {
        view.configure(blockedLeadingInset: blockedLeadingInset, style: style, faviconCandidate: faviconCandidate)
    }
}
