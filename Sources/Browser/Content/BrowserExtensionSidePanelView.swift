import AppKit
import SwiftUI

// MARK: - BrowserExtensionSidePanelView

struct BrowserExtensionSidePanelView: NSViewRepresentable {
    let sidePanel: BrowserExtensionSidePanel
    let hostView: NSView
    let isContextReady: Bool
    let usesWindowContentInsets: Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> BrowserExtensionSidePanelNSView {
        let view = BrowserExtensionSidePanelNSView(hostView: hostView)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserExtensionSidePanelNSView, context _: Context) {
        view.onClose = onClose
        view.update(
            sidePanel: sidePanel,
            hostView: hostView,
            isContextReady: isContextReady,
            usesWindowContentInsets: usesWindowContentInsets
        )
    }
}

// MARK: - BrowserExtensionSidePanelResizeHandle

struct BrowserExtensionSidePanelResizeHandle: NSViewRepresentable {
    @ObservedObject var model: BrowserChromeModel

    func makeNSView(context: Context) -> BrowserNativeResizeHandle {
        let view = BrowserNativeResizeHandle()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserNativeResizeHandle, context _: Context) {
        view
            .getWidth = { [weak model] in
                model?.extensionSidePanelWidth ?? BrowserChromeModel.defaultExtensionSidePanelWidth
            }
        view.setWidth = { [weak model] in model?.setExtensionSidePanelWidth($0) }
        view.defaultWidth = BrowserChromeModel.defaultExtensionSidePanelWidth
        view.direction = -1
        view.hapticsEnabled = model.userPreferencesStore.hapticFeedbackEnabled
    }
}
