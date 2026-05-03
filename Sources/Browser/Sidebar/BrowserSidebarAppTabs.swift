import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSidebarAppTabsGrid

struct BrowserSidebarAppTabsGrid: View {
    // MARK: Internal

    let tabs: [BrowserChromeModel.Tab]
    let draggedTabID: String?
    let isSidebarResizing: Bool
    let sidebarContentWidth: CGFloat
    let onSelect: (String) -> Void
    let onDragChanged: (String, DragGesture.Value) -> Void
    let onDragEnded: (String, DragGesture.Value) -> Void

    let layout = BrowserSidebarAppTabGridLayout(spacing: BrowserChromeLayout.appTabGridSpacing)

    var gridHeight: CGFloat {
        max(
            layout.height(for: tabs.count, availableWidth: sidebarContentWidth),
            BrowserChromeLayout.sidebarEmptySectionDropZoneHeight
        )
    }

    var body: some View {
        let frames = layout.frames(for: tabs.count, availableWidth: sidebarContentWidth)

        ZStack(alignment: .topLeading) {
            if tabs.isEmpty {
                Color.clear
                    .frame(height: BrowserChromeLayout.sidebarEmptySectionDropZoneHeight)
            }

            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if frames.indices.contains(index) {
                    let frame = frames[index]
                    appTabTile(tab, sectionIndex: index)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: gridHeight, alignment: .top)
        .animation(BrowserChromeLayout.sidebarTabDropListAnimation, value: tabs.map(\.id))
        .browserSidebarAppTabsContainerFrame()
    }

    // MARK: Private

    private func appTabTile(_ tab: BrowserChromeModel.Tab, sectionIndex: Int) -> some View {
        BrowserSidebarAppTabTile(
            tab: tab,
            isSidebarResizing: isSidebarResizing,
            onSelect: {
                onSelect(tab.id)
            }
        )
        .browserSidebarAppTabFrame(tabID: tab.id, sectionIndex: sectionIndex)
        .transition(BrowserChromeLayout.sidebarTabVisibilityTransition)
        .opacity(draggedTabID == tab.id ? 0 : 1)
        .allowsHitTesting(draggedTabID != tab.id)
        .simultaneousGesture(
            DragGesture(
                minimumDistance: BrowserChromeLayout.sidebarTabDragMinimumDistance,
                coordinateSpace: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
            )
            .onChanged { value in
                onDragChanged(tab.id, value)
            }
            .onEnded { value in
                onDragEnded(tab.id, value)
            }
        )
    }
}

// MARK: - BrowserSidebarAppTabTile

struct BrowserSidebarAppTabTile: View {
    let tab: BrowserChromeModel.Tab
    let isSidebarResizing: Bool
    let onSelect: () -> Void

    @State var isHovered = false
    @State var isPressed = false

    var backgroundColor: Color {
        isHovered ? BrowserChromePalette.currentURLRowHover : BrowserChromePalette.currentURLRow
    }

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
                    .fill(backgroundColor)

                BrowserFaviconView(url: tab.faviconURL, size: BrowserChromeLayout.appTabIconSize)
            }
            .contentShape(RoundedRectangle(
                cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius,
                style: .continuous
            ))
        }
        .buttonStyle(
            BrowserSidebarPressTrackingButtonStyle { isPressed in
                self.isPressed = isPressed
            }
        )
        .scaleEffect(isPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isHovered = hovering
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            guard isSidebarResizing else {
                return
            }

            isHovered = false
            isPressed = false
        }
        .browserTooltip(
            title: tab.displayTitle,
            shortcut: nil,
            isPresented: isHovered && !isSidebarResizing
        )
    }
}
