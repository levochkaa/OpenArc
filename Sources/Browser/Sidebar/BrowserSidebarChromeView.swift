import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSidebarChromeView

struct BrowserSidebarChromeView: View {
    @ObservedObject var model: BrowserChromeModel
    @ObservedObject var updateController: BrowserUpdateController
    let snapshot: BrowserSidebarSnapshot
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let showsCurrentURLRow: Bool
    let sidebarWidth: CGFloat
    let isOverlayPresentation: Bool
    let showsOverlayBorder: Bool
    var roundsWindowLeadingCorners = false
    let toggleSidebarTooltipTitle: String
    let ownedBackgroundMode: BrowserChromeBackgroundMode?
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    @State var isSidebarResizing = false

    var sidebarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: sidebarCornerRadii,
            style: .continuous
        )
    }

    var sidebarCornerRadii: RectangleCornerRadii {
        if usesOverlayShape {
            let cornerRadius = BrowserChromeLayout.sidebarOverlayCornerRadius
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            )
        }

        if roundsWindowLeadingCorners {
            let cornerRadius = BrowserWindowGeometry.windowCornerRadius
            return RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            )
        }

        return RectangleCornerRadii()
    }

    var usesOverlayShape: Bool {
        isOverlayPresentation || showsOverlayBorder
    }

    var body: some View {
        sidebarContent
            .clipShape(sidebarShape)
            .overlay {
                if showsOverlayBorder {
                    sidebarShape
                        .strokeBorder(
                            BrowserChromePalette.sidebarOverlayBorder,
                            lineWidth: BrowserChromeLayout.sidebarOverlayBorderWidth
                        )
                        .transition(.opacity)
                }
            }
            .animation(
                .easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration),
                value: showsOverlayBorder
            )
    }

    var sidebarContent: some View {
        BrowserSidebarContainerView(
            model: model,
            updateController: updateController,
            snapshot: snapshot,
            extensions: model.browserExtensions,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar,
            isCommandBarPresented: isCommandBarPresented,
            isCurrentPageCommandBarPresented: isCurrentPageCommandBarPresented,
            showsCurrentURLRow: showsCurrentURLRow,
            sidebarWidth: sidebarWidth,
            isSidebarResizing: isSidebarResizing,
            toggleSidebarTooltipTitle: toggleSidebarTooltipTitle,
            onToggleSidebar: onToggleSidebar,
            onURLRowFrameChange: onURLRowFrameChange
        )
        .background {
            if let ownedBackgroundMode {
                BrowserChromeBackgroundView(mode: ownedBackgroundMode)
            }
        }
        .overlay(alignment: .trailing) {
            BrowserSidebarResizeHandle(model: model, isSidebarResizing: $isSidebarResizing)
                .frame(width: BrowserChromeLayout.sidebarResizeHitWidth)
        }
    }
}

// MARK: - BrowserSidebarContainerView

struct BrowserSidebarContainerView: View {
    let model: BrowserChromeModel
    let updateController: BrowserUpdateController
    let snapshot: BrowserSidebarSnapshot
    let extensions: [BrowserExtension]
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let showsCurrentURLRow: Bool
    let sidebarWidth: CGFloat
    let isSidebarResizing: Bool
    let toggleSidebarTooltipTitle: String
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    var body: some View {
        BrowserSidebarView(
            model: model,
            updateController: updateController,
            snapshot: snapshot,
            extensions: extensions,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar,
            isCommandBarPresented: isCommandBarPresented,
            isCurrentPageCommandBarPresented: isCurrentPageCommandBarPresented,
            showsCurrentURLRow: showsCurrentURLRow,
            sidebarWidth: sidebarWidth,
            isSidebarResizing: isSidebarResizing,
            toggleSidebarTooltipTitle: toggleSidebarTooltipTitle,
            onToggleSidebar: onToggleSidebar,
            onURLRowFrameChange: onURLRowFrameChange
        )
    }
}

// MARK: - BrowserSidebarResizeHandle

struct BrowserSidebarResizeHandle: View {
    // MARK: Internal

    @ObservedObject var model: BrowserChromeModel
    @Binding var isSidebarResizing: Bool

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
                updateSidebarWidth(with: value.translation.width)
            }
            .onEnded { _ in
                finishResize()
            }
    }

    var body: some View {
        Color.clear
            .overlay {
                if shouldShowResizeHandle {
                    Rectangle()
                        .fill(
                            isResizeHovered
                                ? BrowserChromePalette.resizeHandleHover
                                : BrowserChromePalette.resizeHandle
                        )
                        .frame(width: 2)
                }
            }
            .padding(.vertical, BrowserChromeLayout.sidebarOuterPadding)
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
                isSidebarResizing = false
                isSnappedToDefaultWidth = false
                dragStartWidth = nil
            }
    }

    // MARK: Private

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
            dragStartWidth = model.sidebarWidth
        }

        isResizing = true
        isSidebarResizing = true

        pushResizeCursorIfNeeded()
    }

    private func updateSidebarWidth(with translation: CGFloat) {
        let baseWidth = dragStartWidth ?? model.sidebarWidth
        let proposedWidth = baseWidth + translation
        let shouldSnapToDefault =
            abs(proposedWidth - BrowserChromeModel.defaultSidebarWidth) <= BrowserChromeLayout.sidebarSnapThreshold

        if shouldSnapToDefault {
            model.setSidebarWidth(BrowserChromeModel.defaultSidebarWidth)

            if !isSnappedToDefaultWidth {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        } else {
            model.setSidebarWidth(proposedWidth)
        }

        isSnappedToDefaultWidth = shouldSnapToDefault
    }

    private func finishResize() {
        let shouldPersistSidebarWidth =
            if let dragStartWidth {
                dragStartWidth != model.sidebarWidth
            } else {
                false
            }

        dragStartWidth = nil
        isResizing = false
        isSidebarResizing = false
        isSnappedToDefaultWidth = false

        if shouldPersistSidebarWidth {
            model.persistSidebarWidthPreferenceIfAllowed()
        }

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
