import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserExtensionSidePanelView

struct BrowserExtensionSidePanelView: View {
    let sidePanel: BrowserExtensionSidePanel
    let hostView: NSView
    let isContextReady: Bool
    let usesWindowContentInsets: Bool
    let onClose: () -> Void

    @State var isCloseHovered = false

    var panelCornerRadius: CGFloat {
        usesWindowContentInsets ? BrowserChromeLayout.leadingContentCornerRadius : 0
    }

    var panelContentMaskedCorners: CACornerMask {
        guard usesWindowContentInsets else {
            return []
        }

        return [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            BrowserViewportHostRepresentable(
                hostView: hostView,
                cornerRadius: panelCornerRadius,
                maskedCorners: panelContentMaskedCorners
            )
            .overlay {
                if !isContextReady {
                    Rectangle()
                        .fill(BrowserChromePalette.contentBackground)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
    }

    var header: some View {
        HStack(spacing: 8) {
            icon

            Text(sidePanel.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: BrowserChromeLayout.sidebarCloseSymbolSize, weight: .bold))
                    .foregroundStyle(BrowserChromePalette.rowCloseForeground)
                    .frame(
                        width: BrowserChromeLayout.extensionSidePanelCloseButtonSize,
                        height: BrowserChromeLayout.extensionSidePanelCloseButtonSize
                    )
                    .background {
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius,
                            style: .continuous
                        )
                        .fill(isCloseHovered ? BrowserChromePalette.rowCloseHover : .clear)
                    }
            }
            .buttonStyle(BrowserSidebarCloseButtonStyle())
            .onHover { isCloseHovered = $0 }
            .browserTooltip(
                title: BrowserStrings.extensionsCloseSidePanel,
                shortcut: nil,
                isPresented: isCloseHovered
            )
        }
        .padding(.horizontal, BrowserChromeLayout.extensionSidePanelHeaderHorizontalPadding)
        .frame(height: BrowserChromeLayout.extensionSidePanelHeaderHeight)
    }

    @ViewBuilder var icon: some View {
        if let iconData = sidePanel.iconData, let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(
                    width: BrowserChromeLayout.extensionSidePanelHeaderIconSize,
                    height: BrowserChromeLayout.extensionSidePanelHeaderIconSize
                )
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: BrowserChromeLayout.extensionSidePanelHeaderIconSize, weight: .medium))
                .foregroundStyle(BrowserChromePalette.primaryText)
        }
    }
}

// MARK: - BrowserExtensionSidePanelResizeHandle

struct BrowserExtensionSidePanelResizeHandle: View {
    // MARK: Internal

    @ObservedObject var model: BrowserChromeModel

    @State var isHoveringResizeArea = false
    @State var isResizeHovered = false
    @State var isResizing = false
    @State var isSnappedToDefaultWidth = false
    @State var dragStartWidth: CGFloat?
    @State var pushedResizeCursor = false

    var shouldShowResizeHandle: Bool {
        isResizeHovered || isResizing
    }

    var resizeHoverActivationTaskID: Int {
        (isHoveringResizeArea ? 1 : 0) | (isResizing ? 2 : 0)
    }

    var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                beginResizeIfNeeded()
                updatePanelWidth(with: value.translation.width)
            }
            .onEnded { _ in
                finishResize()
            }
    }

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay {
                Rectangle()
                    .fill(isResizeHovered ? BrowserChromePalette.resizeHandleHover : BrowserChromePalette.resizeHandle)
                    .frame(width: 2)
                    .opacity(shouldShowResizeHandle ? 1 : 0)
            }
            .padding(.vertical, usesVerticalPadding ? BrowserChromeLayout.sidebarOuterPadding : 0)
            .contentShape(Rectangle())
            .onHover(perform: handleResizeHover)
            .task(id: resizeHoverActivationTaskID) {
                await activateResizeHoverIfNeeded()
            }
            .gesture(resizeGesture)
            .onDisappear {
                popResizeCursorIfNeeded()
                isHoveringResizeArea = false
                isResizeHovered = false
                isResizing = false
                isSnappedToDefaultWidth = false
                dragStartWidth = nil
            }
    }

    // MARK: Private

    private var usesVerticalPadding: Bool {
        true
    }

    private func handleResizeHover(_ hovering: Bool) {
        isHoveringResizeArea = hovering

        if !hovering {
            isResizeHovered = false
            if !isResizing {
                popResizeCursorIfNeeded()
            }
        }
    }

    private func beginResizeIfNeeded() {
        if dragStartWidth == nil {
            dragStartWidth = model.extensionSidePanelWidth
        }

        isResizing = true
        pushResizeCursorIfNeeded()
    }

    private func updatePanelWidth(with translation: CGFloat) {
        let baseWidth = dragStartWidth ?? model.extensionSidePanelWidth
        let proposedWidth = baseWidth - translation
        let shouldSnapToDefault =
            abs(proposedWidth - BrowserChromeModel.defaultExtensionSidePanelWidth) <= BrowserChromeLayout
                .sidebarSnapThreshold

        if shouldSnapToDefault {
            model.setExtensionSidePanelWidth(BrowserChromeModel.defaultExtensionSidePanelWidth)

            if !isSnappedToDefaultWidth {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else {
            model.setExtensionSidePanelWidth(proposedWidth)
        }

        isSnappedToDefaultWidth = shouldSnapToDefault
    }

    private func finishResize() {
        dragStartWidth = nil
        isResizing = false
        isSnappedToDefaultWidth = false

        guard isHoveringResizeArea else {
            isResizeHovered = false
            popResizeCursorIfNeeded()
            return
        }

        if !isResizeHovered {
            popResizeCursorIfNeeded()
        }
    }

    private func activateResizeHoverIfNeeded() async {
        guard isHoveringResizeArea, !isResizing else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarResizeHoverDelayNanoseconds)
        } catch {
            return
        }

        guard isHoveringResizeArea, !isResizing else {
            return
        }

        isResizeHovered = true
        pushResizeCursorIfNeeded()
    }

    private func pushResizeCursorIfNeeded() {
        guard !pushedResizeCursor else {
            return
        }

        NSCursor.resizeLeftRight.push()
        pushedResizeCursor = true
    }

    private func popResizeCursorIfNeeded() {
        guard pushedResizeCursor else {
            return
        }

        NSCursor.pop()
        pushedResizeCursor = false
    }
}
