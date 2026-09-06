import AppKit
import SwiftUI

/// Temporary adapter. Loading and rendering belong to the native favicon view.
struct BrowserFaviconView: NSViewRepresentable {
    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let url: URL?
    var pageURLString: String?
    var size: CGFloat = BrowserChromeLayout.sidebarFaviconSize

    func makeNSView(context _: Context) -> BrowserFaviconNSView {
        let view = BrowserFaviconNSView(cache: faviconCache)
        view.update(url: url, pageURLString: pageURLString)
        return view
    }

    func updateNSView(_ view: BrowserFaviconNSView, context _: Context) {
        view.update(url: url, pageURLString: pageURLString)
    }

    func sizeThatFits(_: ProposedViewSize, nsView _: BrowserFaviconNSView, context _: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
