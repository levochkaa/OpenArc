import AppKit
import QuartzCore
import SwiftUI

struct BrowserFaviconView: View {
    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let url: URL?
    var size: CGFloat = BrowserChromeLayout.sidebarFaviconSize

    var body: some View {
        Group {
            if let image = faviconCache.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            await faviconCache.loadImageIfNeeded(from: url)
        }
    }

    var placeholder: some View {
        Image(systemName: "globe")
            .resizable()
            .scaledToFit()
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .padding(1)
    }
}
