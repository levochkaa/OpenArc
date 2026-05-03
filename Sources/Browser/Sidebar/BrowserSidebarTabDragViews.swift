import AppKit
import QuartzCore
import SwiftUI

struct BrowserSidebarTabDragEventMonitor: NSViewRepresentable {
    let tabID: String
    let onDragged: (String, CGPoint) -> Void
    let onEnded: (String, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BrowserSidebarTabDragEventMonitorView {
        let view = BrowserSidebarTabDragEventMonitorView()
        context.coordinator.update(
            view: view,
            tabID: tabID,
            onDragged: onDragged,
            onEnded: onEnded
        )
        return view
    }

    func updateNSView(_ nsView: BrowserSidebarTabDragEventMonitorView, context: Context) {
        context.coordinator.update(
            view: nsView,
            tabID: tabID,
            onDragged: onDragged,
            onEnded: onEnded
        )
    }

    static func dismantleNSView(_: BrowserSidebarTabDragEventMonitorView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        private weak var view: BrowserSidebarTabDragEventMonitorView?
        var localMonitor: Any?
        var tabID: String?
        var onDragged: ((String, CGPoint) -> Void)?
        var onEnded: ((String, CGPoint) -> Void)?

        func update(
            view: BrowserSidebarTabDragEventMonitorView,
            tabID: String,
            onDragged: @escaping (String, CGPoint) -> Void,
            onEnded: @escaping (String, CGPoint) -> Void
        ) {
            self.view = view
            self.tabID = tabID
            self.onDragged = onDragged
            self.onEnded = onEnded
            installMonitorIfNeeded()
        }

        func removeMonitor() {
            guard let localMonitor else {
                return
            }

            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        private func installMonitorIfNeeded() {
            guard localMonitor == nil else {
                return
            }

            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard
                let view,
                event.window === view.window,
                let tabID
            else {
                return
            }

            let location = view.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDragged:
                onDragged?(tabID, location)
            case .leftMouseUp:
                onEnded?(tabID, location)
                removeMonitor()
            default:
                break
            }
        }
    }
}
final class BrowserSidebarTabDragEventMonitorView: NSView {
    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
struct BrowserSidebarTabDragPreviewOverlay: View {
    @ObservedObject var store: BrowserSidebarTabDragPreviewStore
    let snapshot: BrowserSidebarSnapshot

    var body: some View {
        if let preview = store.preview, let tab = snapshot.tab(withID: preview.tabID) {
            BrowserSidebarTabDragPreview(
                tab: tab,
                style: dragPreviewStyle(for: preview.size)
            )
            .equatable()
            .frame(width: preview.size.width, height: preview.size.height)
            .position(preview.center)
            .animation(BrowserChromeLayout.sidebarTabDragPreviewAnimation, value: preview.size)
            .allowsHitTesting(false)
        }
    }

    private func dragPreviewStyle(for size: CGSize) -> BrowserSidebarTabDragPreview.Style {
        abs(size.height - BrowserChromeLayout.sidebarRowHeight) > 0.5 ? .appTile : .row
    }
}
struct BrowserSidebarTabDragPreview: View {
    enum Style {
        case row
        case appTile
    }

    let tab: BrowserChromeModel.Tab
    let style: Style

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
                    .fill(BrowserChromePalette.rowSelected)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
                    .stroke(BrowserChromePalette.sidebarDropIndicator.opacity(0.28), lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(0.32),
                radius: BrowserChromeLayout.sidebarDragPreviewShadowRadius,
                y: BrowserChromeLayout.sidebarDragPreviewShadowY
            )
            .compositingGroup()
    }

    @ViewBuilder
    var content: some View {
        switch style {
        case .row:
            HStack(spacing: 0) {
                BrowserFaviconView(url: tab.faviconURL)
                Spacer(minLength: 0)
                    .frame(width: BrowserChromeLayout.sidebarRowContentSpacing)

                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
            .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: BrowserChromeLayout.sidebarRowHeight,
                maxHeight: BrowserChromeLayout.sidebarRowHeight,
                alignment: .leading
            )
        case .appTile:
            BrowserFaviconView(url: tab.faviconURL, size: BrowserChromeLayout.appTabIconSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
extension BrowserSidebarTabDragPreview: Equatable {}
