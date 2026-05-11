import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSiteControlCenterPopover

struct BrowserSiteControlCenterPopover: View {
    let extensions: [BrowserExtension]
    let onManageExtensions: () -> Void
    let onAddExtension: () -> Void
    let onSelectExtension: (String) -> Void

    var gridItems: [BrowserExtensionControlCenterItem] {
        BrowserExtensionControlCenterModel.gridItems(for: extensions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserChromeLayout.siteControlPopoverSpacing) {
            HStack(spacing: 10) {
                Text(BrowserStrings.extensionsSectionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Button(BrowserStrings.extensionsManageAction, action: onManageExtensions)
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .fixed(BrowserChromeLayout.extensionTileSize),
                        spacing: BrowserChromeLayout.extensionGridSpacing
                    ),
                    count: BrowserExtensionControlCenterModel.maximumVisibleTiles
                ),
                alignment: .leading,
                spacing: BrowserChromeLayout.extensionGridSpacing
            ) {
                ForEach(gridItems) { item in
                    BrowserExtensionControlCenterTile(
                        item: item,
                        onAddExtension: onAddExtension,
                        onSelectExtension: onSelectExtension
                    )
                }
            }
        }
        .padding(BrowserChromeLayout.siteControlPopoverPadding)
        .frame(width: BrowserChromeLayout.siteControlPopoverWidth, alignment: .topLeading)
    }
}

// MARK: - BrowserExtensionControlCenterTile

struct BrowserExtensionControlCenterTile: View {
    // MARK: Internal

    let item: BrowserExtensionControlCenterItem
    let onAddExtension: () -> Void
    let onSelectExtension: (String) -> Void

    var iconOpacity: Double {
        switch item.kind {
        case .installed(let browserExtension):
            browserExtension.isEnabled ? 1 : 0.38
        case .add:
            1
        }
    }

    var accessibilityLabel: String {
        switch item.kind {
        case .installed(let browserExtension):
            browserExtension.name
        case .add:
            BrowserStrings.extensionsAddAction
        }
    }

    var body: some View {
        Button(action: performAction) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: BrowserChromeLayout.extensionTileCornerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .controlBackgroundColor))

                tileIcon
                    .opacity(iconOpacity)
            }
            .frame(
                width: BrowserChromeLayout.extensionTileSize,
                height: BrowserChromeLayout.extensionTileSize
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder var tileIcon: some View {
        switch item.kind {
        case .installed(let browserExtension):
            if let iconImage = browserExtension.iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: BrowserChromeLayout.extensionTileIconSize,
                        height: BrowserChromeLayout.extensionTileIconSize
                    )
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: BrowserChromeLayout.extensionTileIconSize, weight: .medium))
                    .foregroundStyle(.primary)
            }
        case .add:
            Image(systemName: "plus")
                .font(.system(size: BrowserChromeLayout.extensionTileIconSize, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    // MARK: Private

    private func performAction() {
        switch item.kind {
        case .installed(let browserExtension):
            onSelectExtension(browserExtension.id)
        case .add:
            onAddExtension()
        }
    }
}

// MARK: - BrowserSidebarCurrentURLRow

struct BrowserSidebarCurrentURLRow: View {
    // MARK: Internal

    let tab: BrowserChromeModel.Tab?
    let extensions: [BrowserExtension]
    let copyLinkShortcut: BrowserKeyboardShortcut
    let isSearchPresented: Bool
    let isSidebarResizing: Bool
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let onFrameChange: (CGRect?) -> Void
    let onOpenSearch: () -> Void
    let onCopyURL: () -> Bool
    let onRefreshExtensions: () -> Void
    let onOpenExtensionsManager: () -> Void
    let onOpenExtensionStore: () -> Void
    let onOpenExtensionDetails: (String) -> Void

    @State var isRowHovered = false
    @State var isCopyHovered = false
    @State var isSiteControlHovered = false
    @State var didCopyURL = false
    @State var isSiteControlCenterPresented = false
    @State var copyFeedbackTask: Task<Void, Never>?

    var rowBackgroundColor: Color {
        isRowHovered || isSearchPresented
            ? BrowserChromePalette.currentURLRowHover
            : BrowserChromePalette.currentURLRow
    }

    var rowBackgroundResolvedColor: Color {
        isRowHovered || isSearchPresented
            ? BrowserChromePalette.currentURLRowHoverResolved
            : BrowserChromePalette.currentURLRowResolved
    }

    var showsActionButtons: Bool {
        isRowHovered && !isSidebarResizing && tab != nil
    }

    var isActionButtonHovered: Bool {
        isCopyHovered || isSiteControlHovered
    }

    var displayURL: String {
        guard let tab else {
            return BrowserStrings.newTabTitle
        }

        return BrowserURLDisplayFormatter.displayString(for: tab.urlString)
    }

    var fullURLString: String {
        tab?.urlString ?? BrowserStrings.newTabTitle
    }

    var actionButtonOverlayShape: some Shape {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpenSearch) {
                Text(displayURL)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.currentURLText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
                    .frame(height: BrowserChromeLayout.sidebarRowHeight)
                    .background(rowBackgroundShape)
                    .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
            }
            .buttonStyle(BrowserSidebarPressButtonStyle())
            .disabled(tab == nil)
            .browserTooltip(
                title: fullURLString,
                shortcut: nil,
                isPresented: isRowHovered && !isActionButtonHovered && !isSidebarResizing
            )

            actionButtonOverlay
                .opacity(showsActionButtons ? 1 : 0)
                .allowsHitTesting(showsActionButtons)
        }
        .frame(maxWidth: .infinity)
        .background {
            BrowserWindowFrameReader(onFrameChange: onFrameChange)
        }
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isRowHovered = hovering
            if !hovering {
                isCopyHovered = false
                isSiteControlHovered = false
            }
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            guard isSidebarResizing else {
                return
            }

            resetTransientInteractionState()
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            onFrameChange(nil)
            resetTransientInteractionState()
        }
    }

    var actionButtonOverlay: some View {
        HStack(spacing: BrowserChromeLayout.sidebarCurrentURLButtonSpacing) {
            currentURLActionButton(
                systemImageName: didCopyURL ? "checkmark" : "link",
                tooltipTitle: BrowserStrings.tabCopyURLAction,
                tooltipShortcut: copyLinkShortcut,
                isHovered: isCopyHovered,
                onHover: { isCopyHovered = $0 },
                action: copyURL
            )

            currentURLActionButton(
                systemImageName: "slider.horizontal.3",
                tooltipTitle: BrowserStrings.siteControlCenterAction,
                tooltipShortcut: nil,
                isHovered: isSiteControlHovered,
                onHover: { isSiteControlHovered = $0 },
                action: { isSiteControlCenterPresented = true }
            )
            .popover(isPresented: $isSiteControlCenterPresented, arrowEdge: .trailing) {
                BrowserSiteControlCenterPopover(
                    extensions: extensions,
                    onManageExtensions: {
                        isSiteControlCenterPresented = false
                        onOpenExtensionsManager()
                    },
                    onAddExtension: {
                        isSiteControlCenterPresented = false
                        onOpenExtensionStore()
                    },
                    onSelectExtension: { extensionID in
                        isSiteControlCenterPresented = false
                        onOpenExtensionDetails(extensionID)
                    }
                )
                .onAppear(perform: onRefreshExtensions)
            }
        }
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .padding(.leading, BrowserChromeLayout.sidebarCloseButtonLeadingSpacing)
        .frame(
            width: BrowserChromeLayout.sidebarCurrentURLOverlayWidth,
            height: BrowserChromeLayout.sidebarRowHeight,
            alignment: .trailing
        )
        .background(actionButtonOverlayBackground)
    }

    @ViewBuilder var actionButtonOverlayBackground: some View {
        switch chromeBackgroundMode {
        case .blurred:
            actionButtonOverlayBlurredBackground
        case .black:
            actionButtonOverlaySolidBackground
        }
    }

    var actionButtonOverlayBlurredBackground: some View {
        ZStack {
            BrowserChromeBackgroundView(mode: .blurred)
            rowBackgroundColor
        }
        .mask(actionButtonOverlayMask)
        .clipShape(actionButtonOverlayShape)
    }

    var actionButtonOverlaySolidBackground: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.clear,
                    rowBackgroundResolvedColor,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: BrowserChromeLayout.sidebarCurrentURLOverlayFadeWidth)

            rowBackgroundResolvedColor
                .frame(width: BrowserChromeLayout.sidebarCurrentURLOverlaySolidWidth)
        }
        .clipShape(actionButtonOverlayShape)
    }

    var actionButtonOverlayMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black,
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: BrowserChromeLayout.sidebarCurrentURLOverlayFadeWidth)

            Color.black
                .frame(width: BrowserChromeLayout.sidebarCurrentURLOverlaySolidWidth)
        }
    }

    var rowBackgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius, style: .continuous)
            .fill(rowBackgroundColor)
    }

    // MARK: Private

    private func currentURLActionButton(
        systemImageName: String,
        tooltipTitle: String,
        tooltipShortcut: BrowserKeyboardShortcut?,
        isHovered: Bool,
        onHover: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                    style: .continuous
                )
                .fill(isHovered ? BrowserChromePalette.currentURLButtonHoverResolved : Color.clear)

                ForEach([systemImageName], id: \.self) { imageName in
                    Image(systemName: imageName)
                        .font(.system(size: BrowserChromeLayout.sidebarCurrentURLButtonSymbolSize, weight: .bold))
                        .foregroundStyle(BrowserChromePalette.currentURLText)
                        .transition(.scale(scale: 0.58).combined(with: .opacity))
                }
            }
            .frame(
                width: BrowserChromeLayout.sidebarCurrentURLButtonSize,
                height: BrowserChromeLayout.sidebarCurrentURLButtonSize
            )
        }
        .animation(BrowserChromeLayout.currentURLCopyIconAnimation, value: systemImageName)
        .buttonStyle(BrowserSidebarCloseButtonStyle())
        .contentShape(
            RoundedRectangle(
                cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                style: .continuous
            )
        )
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            onHover(hovering)
        }
        .browserTooltip(
            title: tooltipTitle,
            shortcut: tooltipShortcut,
            isPresented: isHovered && !isSidebarResizing
        )
    }

    private func copyURL() {
        guard onCopyURL() else {
            return
        }

        withAnimation(BrowserChromeLayout.currentURLCopyIconAnimation) {
            didCopyURL = true
        }
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }

            withAnimation(BrowserChromeLayout.currentURLCopyIconAnimation) {
                didCopyURL = false
            }
        }
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isCopyHovered = false
        isSiteControlHovered = false
        isSiteControlCenterPresented = false
    }
}
