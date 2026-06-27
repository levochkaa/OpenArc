import AppKit
import SwiftUI

// MARK: - BrowserTabSwitcherEventObserver

struct BrowserTabSwitcherEventObserver: NSViewRepresentable {
    let isEnabled: Bool
    let onTab: (Bool) -> Bool
    let onCommit: () -> Bool
    let onCancel: () -> Bool

    func makeNSView(context _: Context) -> BrowserTabSwitcherEventNSView {
        let view = BrowserTabSwitcherEventNSView()
        view.isEnabled = isEnabled
        view.onTab = onTab
        view.onCommit = onCommit
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: BrowserTabSwitcherEventNSView, context _: Context) {
        nsView.isEnabled = isEnabled
        nsView.onTab = onTab
        nsView.onCommit = onCommit
        nsView.onCancel = onCancel
    }
}

// MARK: - BrowserTabSwitcherEventNSView

final class BrowserTabSwitcherEventNSView: NSView {
    // MARK: Internal

    var isEnabled = false
    var onTab: (Bool) -> Bool = { _ in false }
    var onCommit: () -> Bool = { false }
    var onCancel: () -> Bool = { false }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeLocalMonitor()
        } else {
            installLocalMonitorIfNeeded()
        }
    }

    // MARK: Private

    private static let tabKeyCode: UInt16 = 48
    private static let escapeKeyCode: UInt16 = 53

    private let localMonitorCleanup = BrowserTabSwitcherMonitorCleanup()

    private static func isOptionTabEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == tabKeyCode
            && modifiers.contains(.option)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
    }

    private static func isOptionReleasedEvent(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitorCleanup.monitor == nil else {
            return
        }

        localMonitorCleanup.set(NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown,
            .flagsChanged,
        ]) { [weak self] event in
            guard let self else {
                return event
            }

            return handle(event)
        })
    }

    private func removeLocalMonitor() {
        localMonitorCleanup.remove()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard
            isEnabled,
            let window,
            event.window == nil || event.window === window
        else {
            return event
        }

        switch event.type {
        case .keyDown:
            if Self.isOptionTabEvent(event) {
                return onTab(event.modifierFlags.contains(.shift)) ? nil : event
            }

            if event.keyCode == Self.escapeKeyCode {
                return onCancel() ? nil : event
            }

            return event
        case .flagsChanged:
            return Self.isOptionReleasedEvent(event) && onCommit() ? nil : event
        default:
            return event
        }
    }
}

// MARK: - BrowserTabSwitcherMonitorCleanup

private final class BrowserTabSwitcherMonitorCleanup: @unchecked Sendable {
    // MARK: Lifecycle

    deinit {
        remove()
    }

    // MARK: Internal

    var monitor: Any?

    func set(_ monitor: Any?) {
        remove()
        self.monitor = monitor
    }

    func remove() {
        guard let monitor else {
            return
        }

        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

// MARK: - BrowserTabSwitcherOverlay

struct BrowserTabSwitcherOverlay: View {
    // MARK: Internal

    let state: BrowserChromeModel.TabSwitcherState

    var body: some View {
        GeometryReader { proxy in
            if !state.entries.isEmpty {
                let layout = BrowserTabSwitcherOverlayLayout(
                    containerSize: proxy.size,
                    entryCount: state.entries.count
                )

                HStack(spacing: layout.cardSpacing) {
                    ForEach(state.entries) { entry in
                        BrowserTabSwitcherCard(
                            entry: entry,
                            isSelected: entry.id == state.selectedTabID,
                            cardWidth: layout.cardWidth
                        )
                    }
                }
                .padding(.horizontal, layout.panelPadding)
                .padding(.vertical, layout.panelPadding)
                .frame(width: layout.panelWidth)
                .background(panelBackground)
                .shadow(color: Color.black.opacity(0.32), radius: 36, y: 18)
                .position(x: proxy.size.width / 2, y: proxy.size.height * 0.45)
            }
        }
    }

    // MARK: Private

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(BrowserChromePalette.commandBarPanelTint)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(BrowserChromePalette.commandBarPanelBorder, lineWidth: 1)
            )
    }
}

// MARK: - BrowserTabSwitcherCard

private struct BrowserTabSwitcherCard: View {
    // MARK: Internal

    let entry: BrowserChromeModel.TabSwitcherEntry
    let isSelected: Bool
    let cardWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(BrowserChromePalette.commandBarPanelBorder, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.tab.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)

                Text(displayURL)
                    .font(.system(size: 11))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: previewWidth, alignment: .leading)
        }
        .padding(6)
        .frame(width: cardWidth, alignment: .topLeading)
        .background(cardBackground)
        .scaleEffect(isSelected ? 1.025 : 1)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    // MARK: Private

    private var previewWidth: CGFloat {
        max(cardWidth - 12, 0)
    }

    private var previewHeight: CGFloat {
        previewWidth * 0.62
    }

    private var displayURL: String {
        BrowserURLDisplayFormatter.displayString(for: entry.tab.urlString)
    }

    private var preview: some View {
        Group {
            if let previewImage = entry.previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else {
                BrowserTabSwitcherPreviewPlaceholder(title: entry.tab.displayTitle)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? BrowserChromePalette.rowSelected : BrowserChromePalette.commandBarFieldTint)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? BrowserChromePalette.primaryText.opacity(0.38) : Color.clear,
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - BrowserTabSwitcherPreviewPlaceholder

private struct BrowserTabSwitcherPreviewPlaceholder: View {
    // MARK: Internal

    let title: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(BrowserChromePalette.contentBackground)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(BrowserChromePalette.commandBarFieldTint)
                    .frame(width: 58, height: 8)

                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(BrowserChromePalette.rowHover)
                        .frame(width: lineWidth(for: index), height: 8)
                }
            }
            .padding(12)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BrowserChromePalette.secondaryText)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    // MARK: Private

    private func lineWidth(for index: Int) -> CGFloat {
        [122, 96, 142, 76][index]
    }
}

// MARK: - BrowserTabSwitcherOverlayLayout

private struct BrowserTabSwitcherOverlayLayout {
    let containerSize: CGSize
    let entryCount: Int

    var panelWidth: CGFloat {
        let maximumWidth = max(containerSize.width * 2 / 3, 280)
        return min(maximumWidth, max(containerSize.width - 32, 0))
    }

    var panelPadding: CGFloat {
        12
    }

    var cardSpacing: CGFloat {
        10
    }

    var cardWidth: CGFloat {
        guard entryCount > 0 else {
            return 0
        }

        let availableWidth = panelWidth
            - panelPadding * 2
            - cardSpacing * CGFloat(max(entryCount - 1, 0))
        return max(floor(availableWidth / CGFloat(entryCount)), 92)
    }
}
