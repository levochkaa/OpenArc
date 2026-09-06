import AppKit
import SwiftUI

extension View {
    func browserTooltip(
        title: String,
        caption: String? = nil,
        shortcut: BrowserKeyboardShortcut?,
        placement: BrowserTooltipPlacement = .belowLeading,
        isPresented: Bool
    ) -> some View {
        background {
            BrowserTooltipAnchorAdapter(
                title: title,
                caption: caption,
                shortcut: shortcut,
                placement: placement,
                isPresented: isPresented
            )
            .allowsHitTesting(false)
        }
    }
}

// MARK: - BrowserTooltipAnchorAdapter

private struct BrowserTooltipAnchorAdapter: NSViewRepresentable {
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
    let isPresented: Bool

    static func dismantleNSView(_ view: BrowserNativeTooltipAnchor, coordinator _: ()) {
        BrowserNativeTooltipPresenter.shared.end(id: view.tooltipID, detached: true)
    }

    func makeNSView(context _: Context) -> BrowserNativeTooltipAnchor { BrowserNativeTooltipAnchor() }
    func updateNSView(_ view: BrowserNativeTooltipAnchor, context _: Context) {
        view.title = title
        view.caption = caption
        view.shortcut = shortcut
        view.placement = placement
        view.isPresented = isPresented
        view.refresh()
    }
}

extension View {
    func browserKeyboardShortcut(_ shortcut: BrowserKeyboardShortcut) -> some View {
        keyboardShortcut(shortcut.swiftUIKeyEquivalent, modifiers: shortcut.swiftUIModifiers)
    }
}

extension BrowserKeyboardShortcut {
    var swiftUIKeyEquivalent: KeyEquivalent {
        guard let keyEquivalent = keyEquivalent.first else {
            return KeyEquivalent(Character(" "))
        }

        return KeyEquivalent(keyEquivalent)
    }

    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []

        if modifiers.contains(.control) {
            result.insert(.control)
        }

        if modifiers.contains(.option) {
            result.insert(.option)
        }

        if modifiers.contains(.shift) {
            result.insert(.shift)
        }

        if modifiers.contains(.command) {
            result.insert(.command)
        }

        return result
    }
}
