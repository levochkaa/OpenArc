import SwiftUI

struct BrowserBookmarksBar: NSViewRepresentable {
    let model: BrowserChromeModel

    func makeNSView(context _: Context) -> BrowserBookmarksBarNSView { BrowserBookmarksBarNSView(model: model) }
    func updateNSView(_ view: BrowserBookmarksBarNSView, context _: Context) { view.refresh() }
}
