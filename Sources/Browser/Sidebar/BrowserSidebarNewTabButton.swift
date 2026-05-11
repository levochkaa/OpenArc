import AppKit
import SwiftUI

struct BrowserSidebarNewTabButton: View {
    // MARK: Internal

    let shortcutStore: BrowserShortcutStore
    let isCommandBarPresented: Bool
    let isSidebarResizing: Bool
    let onToggleCommandBar: () -> Void

    var backgroundColor: Color {
        guard !isSidebarResizing else {
            return .clear
        }

        if isCommandBarPresented {
            return BrowserChromePalette.rowSelected
        }

        if isHovered {
            return BrowserChromePalette.rowHover
        }

        return .clear
    }

    var body: some View {
        Button(action: onToggleCommandBar) {
            HStack(spacing: BrowserChromeLayout.sidebarRowContentSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: BrowserChromeLayout.sidebarNewTabSymbolSize, weight: .semibold))
                Text(BrowserStrings.sidebarNewTab)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
            .frame(height: BrowserChromeLayout.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
                    .fill(backgroundColor)
            )
            .background {
                BrowserScreenFrameReader { screenFrame in
                    self.screenFrame = screenFrame
                }
            }
        }
        .buttonStyle(BrowserSidebarPressButtonStyle())
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isHovered = hovering
        }
        .onChange(of: isCommandBarPresented) { _, isCommandBarPresented in
            if !isCommandBarPresented {
                syncHoverStateWithPointer()
            }
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            if isSidebarResizing {
                isHovered = false
            }
        }
        .onDisappear {
            screenFrame = nil
            isHovered = false
        }
        .browserTooltip(
            title: shortcutStore.descriptor(for: .newTab).helpTitle,
            shortcut: shortcutStore.shortcut(for: .newTab),
            isPresented: isHovered && !isCommandBarPresented && !isSidebarResizing
        )
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var screenFrame: CGRect?

    private func syncHoverStateWithPointer() {
        guard let screenFrame else {
            isHovered = false
            return
        }

        isHovered = screenFrame.contains(NSEvent.mouseLocation)
    }
}
