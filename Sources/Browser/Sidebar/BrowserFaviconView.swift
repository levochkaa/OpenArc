import AppKit
import QuartzCore
import SwiftUI

struct BrowserFaviconView: View {
    // MARK: Lifecycle

    init(
        url: URL?,
        pageURLString: String? = nil,
        size: CGFloat = BrowserChromeLayout.sidebarFaviconSize
    ) {
        self.url = url
        self.pageURLString = pageURLString
        self.size = size
    }

    // MARK: Internal

    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let url: URL?
    let pageURLString: String?
    let size: CGFloat

    var fallbackStyle: BrowserFaviconFallbackStyle {
        BrowserFaviconFallbackStyle.style(forPageURLString: pageURLString)
    }

    var body: some View {
        Group {
            if fallbackStyle == .chromiumWebUI {
                chromiumWebUIPlaceholder
            } else if let image = faviconCache.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard fallbackStyle != .chromiumWebUI else {
                return
            }

            await faviconCache.loadImageIfNeeded(from: url)
        }
    }

    var chromiumWebUIPlaceholder: some View {
        Image("ChromiumWebUIFavicon")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    var placeholder: some View {
        Image(systemName: "globe")
            .resizable()
            .scaledToFit()
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .padding(1)
    }
}
