import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSiteControlCenterPopover

struct BrowserSiteControlCenterPopover: View {
    let extensions: [BrowserExtension]
    let pinnedExtensionIDs: [String]
    let currentHost: String?
    let onManageExtensions: () -> Void
    let onAddExtension: () -> Void
    let onSelectExtension: (String) -> BrowserExtensionActionPopup?
    let onOpenExtensionStore: (String) -> Void
    let onOpenExtensionDetails: (String) -> Void
    let onRemoveExtension: (String) -> Void
    let onToggleExtensionPinned: (String) -> Void

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
                        isPinned: {
                            guard case .installed(let browserExtension) = item.kind else {
                                return false
                            }

                            return pinnedExtensionIDs.contains(browserExtension.id)
                        }(),
                        currentHost: currentHost,
                        onAddExtension: onAddExtension,
                        onSelectExtension: onSelectExtension,
                        onOpenExtensionStore: onOpenExtensionStore,
                        onOpenExtensionDetails: onOpenExtensionDetails,
                        onRemoveExtension: onRemoveExtension,
                        onToggleExtensionPinned: onToggleExtensionPinned
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
    let isPinned: Bool
    let currentHost: String?
    let onAddExtension: () -> Void
    let onSelectExtension: (String) -> BrowserExtensionActionPopup?
    let onOpenExtensionStore: (String) -> Void
    let onOpenExtensionDetails: (String) -> Void
    let onRemoveExtension: (String) -> Void
    let onToggleExtensionPinned: (String) -> Void

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
        .contextMenu {
            contextMenuContent
        }
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

    @ViewBuilder private var contextMenuContent: some View {
        switch item.kind {
        case .installed(let browserExtension):
            BrowserExtensionContextMenuContent(
                browserExtension: browserExtension,
                isPinned: isPinned,
                currentHost: currentHost,
                onSelectExtension: onSelectExtension,
                onOpenExtensionStore: onOpenExtensionStore,
                onOpenExtensionDetails: onOpenExtensionDetails,
                onRemoveExtension: onRemoveExtension,
                onToggleExtensionPinned: onToggleExtensionPinned
            )
        case .add:
            EmptyView()
        }
    }

    private func performAction() {
        switch item.kind {
        case .installed(let browserExtension):
            _ = onSelectExtension(browserExtension.id)
        case .add:
            onAddExtension()
        }
    }
}

// MARK: - BrowserExtensionContextMenuContent

struct BrowserExtensionContextMenuContent: View {
    let browserExtension: BrowserExtension
    let isPinned: Bool
    let currentHost: String?
    let onSelectExtension: (String) -> BrowserExtensionActionPopup?
    let onOpenExtensionStore: (String) -> Void
    let onOpenExtensionDetails: (String) -> Void
    let onRemoveExtension: (String) -> Void
    let onToggleExtensionPinned: (String) -> Void

    var body: some View {
        Button(browserExtension.name) {
            onOpenExtensionStore(browserExtension.id)
        }

        Divider()

        Menu(BrowserStrings.extensionsSiteAccessMenu) {
            Button(BrowserStrings.extensionsSiteAccessOnClick) {}

            if let currentHost, !currentHost.isEmpty {
                Button(String(format: BrowserStrings.extensionsSiteAccessCurrentSite, currentHost)) {}
            }

            Button {} label: {
                Label(BrowserStrings.extensionsSiteAccessAllSites, systemImage: "checkmark")
            }

            Divider()

            Button(BrowserStrings.extensionsSiteAccessLearnMore) {}
        }

        Divider()

        Button(BrowserStrings.extensionsRemoveFromTheBrowser) {
            onRemoveExtension(browserExtension.id)
        }

        Button(isPinned ? BrowserStrings.extensionsUnpinAction : BrowserStrings.extensionsPinAction) {
            onToggleExtensionPinned(browserExtension.id)
        }

        Divider()

        Button(BrowserStrings.extensionsManageExtension) {
            onOpenExtensionDetails(browserExtension.id)
        }

        Button(BrowserStrings.extensionsViewWebPermissions) {
            onOpenExtensionDetails(browserExtension.id)
        }

        Divider()

        Button(BrowserStrings.extensionsInspectPopup) {
            _ = onSelectExtension(browserExtension.id)
        }
        .disabled(true)
    }
}

// MARK: - BrowserExtensionActionPopupView

struct BrowserExtensionActionPopupView: View {
    let popup: BrowserExtensionActionPopup

    var body: some View {
        BrowserViewportHostRepresentable(
            hostView: popup.hostView,
            cornerRadius: BrowserChromeLayout.extensionActionPopupCornerRadius,
            maskedCorners: [
                .layerMinXMinYCorner,
                .layerMaxXMinYCorner,
                .layerMinXMaxYCorner,
                .layerMaxXMaxYCorner,
            ]
        )
        .frame(
            width: BrowserChromeLayout.extensionActionPopupWidth,
            height: BrowserChromeLayout.extensionActionPopupHeight
        )
        .background(BrowserChromePalette.contentBackground)
        .clipShape(RoundedRectangle(
            cornerRadius: BrowserChromeLayout.extensionActionPopupCornerRadius,
            style: .continuous
        ))
        .onDisappear {
            popup.close()
        }
    }
}

// MARK: - BrowserSidebarCurrentURLRow

struct BrowserSidebarCurrentURLRow: View {
    // MARK: Internal

    let tab: BrowserChromeModel.Tab?
    let extensions: [BrowserExtension]
    let pinnedExtensionIDs: [String]
    let copyLinkShortcut: BrowserKeyboardShortcut
    let toggleBookmarksBarShortcut: BrowserKeyboardShortcut
    let isSearchPresented: Bool
    let isSidebarResizing: Bool
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let isSiteToolbarPresented: Bool
    let siteToolbarShowsFullURL: Bool
    let isBookmarksBarVisible: Bool
    let onFrameChange: (CGRect?) -> Void
    let onOpenSearch: () -> Void
    let onCopyURL: () -> Bool
    let onCaptureFullPage: () -> Bool
    let onToggleSiteToolbar: () -> Void
    let onToggleSiteToolbarFullURL: () -> Void
    let onToggleBookmarksBar: () -> Void
    let onRefreshExtensions: () -> Void
    let onOpenExtensionsManager: () -> Void
    let onOpenExtensionStore: () -> Void
    let onOpenExtensionStorePage: (String) -> Void
    let onOpenExtensionDetails: (String) -> Void
    let onRemoveExtension: (String) -> Void
    let onToggleExtensionPinned: (String) -> Void
    let onOpenExtension: (String) -> BrowserExtensionActionPopup?

    @State var isRowHovered = false
    @State var isCopyHovered = false
    @State var isSiteControlHovered = false
    @State var hoveredPinnedExtensionID: String?
    @State var didCopyURL = false
    @State var isSiteControlCenterPresented = false
    @State var extensionActionPopup: BrowserExtensionActionPopup?
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
        isCopyHovered || isSiteControlHovered || hoveredPinnedExtensionID != nil
    }

    var pinnedExtensions: [BrowserExtension] {
        let extensionsByID = Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0) })
        return pinnedExtensionIDs.compactMap { id in
            guard let browserExtension = extensionsByID[id], browserExtension.isEnabled else {
                return nil
            }

            return browserExtension
        }
    }

    var actionButtonCount: Int {
        pinnedExtensions.count + 2
    }

    var actionButtonsContentWidth: CGFloat {
        let buttonCount = CGFloat(actionButtonCount)
        let spacingCount = CGFloat(max(actionButtonCount - 1, 0))
        return buttonCount * BrowserChromeLayout.sidebarCurrentURLButtonSize
            + spacingCount * BrowserChromeLayout.sidebarCurrentURLButtonSpacing
    }

    var actionOverlaySolidWidth: CGFloat {
        actionButtonsContentWidth
            + BrowserChromeLayout.sidebarTabTrailingPadding
            + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    var actionOverlayWidth: CGFloat {
        actionOverlaySolidWidth + BrowserChromeLayout.sidebarCurrentURLOverlayFadeWidth
    }

    var displayURL: String {
        guard let tab else {
            return BrowserStrings.newTabTitle
        }

        return BrowserURLDisplayFormatter.displayString(for: tab.urlString)
    }

    var fullURLString: String {
        guard let tab else {
            return BrowserStrings.newTabTitle
        }

        return BrowserURLDisplayFormatter.fullDisplayString(for: tab.urlString)
    }

    var currentHost: String? {
        guard
            let urlString = tab?.urlString,
            let url = URL(string: urlString),
            let host = url.host,
            !host.isEmpty
        else {
            return nil
        }

        return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
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
        .contextMenu {
            BrowserSiteURLContextMenuContent(
                tab: tab,
                copyLinkShortcut: copyLinkShortcut,
                toggleBookmarksBarShortcut: toggleBookmarksBarShortcut,
                isToolbarPresented: isSiteToolbarPresented,
                showsFullURL: siteToolbarShowsFullURL,
                isBookmarksBarVisible: isBookmarksBarVisible,
                onCopyURL: {
                    _ = onCopyURL()
                },
                onCaptureFullPage: {
                    _ = onCaptureFullPage()
                },
                onToggleToolbar: onToggleSiteToolbar,
                onToggleShowsFullURL: onToggleSiteToolbarFullURL,
                onToggleBookmarksBar: onToggleBookmarksBar
            )
        }
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isRowHovered = hovering
            if !hovering {
                isCopyHovered = false
                isSiteControlHovered = false
                hoveredPinnedExtensionID = nil
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
            extensionActionPopup?.close()
            extensionActionPopup = nil
            onFrameChange(nil)
            resetTransientInteractionState()
        }
    }

    var actionButtonOverlay: some View {
        HStack(spacing: BrowserChromeLayout.sidebarCurrentURLButtonSpacing) {
            ForEach(pinnedExtensions) { browserExtension in
                currentURLExtensionActionButton(
                    browserExtension: browserExtension,
                    isPinned: pinnedExtensionIDs.contains(browserExtension.id),
                    isHovered: hoveredPinnedExtensionID == browserExtension.id,
                    onHover: { hovering in
                        hoveredPinnedExtensionID = hovering ? browserExtension.id : nil
                    },
                    action: {
                        openExtensionFromActionButton(browserExtension.id)
                    }
                )
            }

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
                    pinnedExtensionIDs: pinnedExtensionIDs,
                    currentHost: currentHost,
                    onManageExtensions: {
                        isSiteControlCenterPresented = false
                        onOpenExtensionsManager()
                    },
                    onAddExtension: {
                        isSiteControlCenterPresented = false
                        onOpenExtensionStore()
                    },
                    onSelectExtension: { extensionID in
                        let popup = onOpenExtension(extensionID)
                        isSiteControlCenterPresented = false
                        extensionActionPopup?.close()
                        extensionActionPopup = popup
                        return popup
                    },
                    onOpenExtensionStore: { extensionID in
                        isSiteControlCenterPresented = false
                        onOpenExtensionStorePage(extensionID)
                    },
                    onOpenExtensionDetails: { extensionID in
                        isSiteControlCenterPresented = false
                        onOpenExtensionDetails(extensionID)
                    },
                    onRemoveExtension: { extensionID in
                        isSiteControlCenterPresented = false
                        onRemoveExtension(extensionID)
                    },
                    onToggleExtensionPinned: { extensionID in
                        onToggleExtensionPinned(extensionID)
                    }
                )
                .onAppear(perform: onRefreshExtensions)
            }
            .popover(item: $extensionActionPopup, arrowEdge: .trailing) { popup in
                BrowserExtensionActionPopupView(popup: popup)
            }
        }
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .padding(.leading, BrowserChromeLayout.sidebarCloseButtonLeadingSpacing)
        .frame(
            width: actionOverlayWidth,
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
                .frame(width: actionOverlaySolidWidth)
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
                .frame(width: actionOverlaySolidWidth)
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

    private func currentURLExtensionActionButton(
        browserExtension: BrowserExtension,
        isPinned: Bool,
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

                if let iconImage = browserExtension.iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: BrowserChromeLayout.sidebarCurrentURLExtensionIconSize,
                            height: BrowserChromeLayout.sidebarCurrentURLExtensionIconSize
                        )
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(
                            size: BrowserChromeLayout.sidebarCurrentURLButtonSymbolSize,
                            weight: .bold
                        ))
                        .foregroundStyle(BrowserChromePalette.currentURLText)
                }
            }
            .frame(
                width: BrowserChromeLayout.sidebarCurrentURLButtonSize,
                height: BrowserChromeLayout.sidebarCurrentURLButtonSize
            )
        }
        .buttonStyle(BrowserSidebarCloseButtonStyle())
        .contentShape(
            RoundedRectangle(
                cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                style: .continuous
            )
        )
        .contextMenu {
            BrowserExtensionContextMenuContent(
                browserExtension: browserExtension,
                isPinned: isPinned,
                currentHost: currentHost,
                onSelectExtension: { extensionID in
                    openExtensionFromActionButton(extensionID)
                    return extensionActionPopup
                },
                onOpenExtensionStore: { extensionID in
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = nil
                    onOpenExtensionStorePage(extensionID)
                },
                onOpenExtensionDetails: { extensionID in
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = nil
                    onOpenExtensionDetails(extensionID)
                },
                onRemoveExtension: { extensionID in
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = nil
                    onRemoveExtension(extensionID)
                },
                onToggleExtensionPinned: onToggleExtensionPinned
            )
        }
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            onHover(hovering)
        }
        .browserTooltip(
            title: browserExtension.name,
            shortcut: nil,
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

    private func openExtensionFromActionButton(_ extensionID: String) {
        isSiteControlCenterPresented = false
        let popup = onOpenExtension(extensionID)
        extensionActionPopup?.close()
        extensionActionPopup = popup
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isCopyHovered = false
        isSiteControlHovered = false
        hoveredPinnedExtensionID = nil
        isSiteControlCenterPresented = false
    }
}

// MARK: - BrowserSiteURLContextMenuContent

struct BrowserSiteURLContextMenuContent: View {
    // MARK: Internal

    let tab: BrowserChromeModel.Tab?
    let copyLinkShortcut: BrowserKeyboardShortcut
    let toggleBookmarksBarShortcut: BrowserKeyboardShortcut
    let isToolbarPresented: Bool
    let showsFullURL: Bool
    let isBookmarksBarVisible: Bool
    let onCopyURL: () -> Void
    let onCaptureFullPage: () -> Void
    let onToggleToolbar: () -> Void
    let onToggleShowsFullURL: () -> Void
    let onToggleBookmarksBar: () -> Void

    var body: some View {
        Button(BrowserStrings.tabCopyURLAction, action: onCopyURL)
            .browserKeyboardShortcut(copyLinkShortcut)
            .disabled(tab == nil)

        BrowserSharingServicesMenu(
            sharingItems: sharingItems,
            subject: tab?.displayTitle ?? BrowserStrings.newTabTitle
        )
        .disabled(tab == nil)

        Button(BrowserStrings.siteCaptureFullPageAction, action: onCaptureFullPage)
            .disabled(tab == nil)

        Divider()

        Button(isToolbarPresented ? BrowserStrings.siteShowInSidebarAction : BrowserStrings.siteShowAsToolbarAction) {
            onToggleToolbar()
        }

        if isToolbarPresented {
            Button(
                showsFullURL ? BrowserStrings.siteHideFullURLAction : BrowserStrings.siteShowFullURLAction,
                action: onToggleShowsFullURL
            )
            .disabled(tab == nil)
        }

        Divider()

        BrowserBookmarksBarVisibilityMenuContent(
            isBookmarksBarVisible: isBookmarksBarVisible,
            toggleBookmarksBarShortcut: toggleBookmarksBarShortcut,
            onToggleBookmarksBar: onToggleBookmarksBar
        )
    }

    // MARK: Private

    private var sharingItems: [Any] {
        guard let tab else {
            return []
        }

        if let pageURL = tab.pageURL {
            return [pageURL]
        }

        return [NSString(string: tab.urlString)]
    }
}

// MARK: - BrowserSiteToolbar

struct BrowserSiteToolbar: View {
    // MARK: Internal

    let tab: BrowserChromeModel.Tab?
    let extensions: [BrowserExtension]
    let pinnedExtensionIDs: [String]
    let canGoBack: Bool
    let canGoForward: Bool
    let canStopLoading: Bool
    let canReload: Bool
    let goBackShortcut: BrowserKeyboardShortcut
    let goForwardShortcut: BrowserKeyboardShortcut
    let reloadShortcut: BrowserKeyboardShortcut
    let copyLinkShortcut: BrowserKeyboardShortcut
    let toggleBookmarksBarShortcut: BrowserKeyboardShortcut
    let showsFullURL: Bool
    let isBookmarksBarVisible: Bool
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let onURLButtonFrameChange: (CGRect?) -> Void
    let onOpenSearch: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onStopLoading: () -> Void
    let onReload: () -> Void
    let onCopyURL: () -> Bool
    let onCaptureFullPage: () -> Bool
    let onToggleToolbar: () -> Void
    let onToggleShowsFullURL: () -> Void
    let onToggleBookmarksBar: () -> Void
    let onRefreshExtensions: () -> Void
    let onOpenExtensionsManager: () -> Void
    let onOpenExtensionStore: () -> Void
    let onOpenExtensionStorePage: (String) -> Void
    let onOpenExtensionDetails: (String) -> Void
    let onRemoveExtension: (String) -> Void
    let onToggleExtensionPinned: (String) -> Void
    let onOpenExtension: (String) -> BrowserExtensionActionPopup?

    var body: some View {
        ZStack {
            BrowserWindowDragRegion()

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                leftToolbarControls
                    .frame(maxWidth: .infinity, alignment: .leading)

                urlToolbarCluster
                    .layoutPriority(1)

                rightToolbarControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, BrowserChromeLayout.bookmarksBarHorizontalPadding)
        }
        .frame(height: BrowserChromeLayout.siteToolbarHeight)
        .background {
            ZStack {
                BrowserChromeBackgroundView(mode: chromeBackgroundMode)
                BrowserWindowDragRegion()
            }
        }
        .contextMenu {
            BrowserSiteURLContextMenuContent(
                tab: tab,
                copyLinkShortcut: copyLinkShortcut,
                toggleBookmarksBarShortcut: toggleBookmarksBarShortcut,
                isToolbarPresented: true,
                showsFullURL: showsFullURL,
                isBookmarksBarVisible: isBookmarksBarVisible,
                onCopyURL: {
                    _ = onCopyURL()
                },
                onCaptureFullPage: {
                    _ = onCaptureFullPage()
                },
                onToggleToolbar: onToggleToolbar,
                onToggleShowsFullURL: onToggleShowsFullURL,
                onToggleBookmarksBar: onToggleBookmarksBar
            )
        }
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            extensionActionPopup?.close()
            extensionActionPopup = nil
            isSiteControlCenterPresented = false
            hoveredPinnedExtensionID = nil
            onURLButtonFrameChange(nil)
        }
    }

    // MARK: Private

    @State private var didCopyURL = false
    @State private var isSiteControlCenterPresented = false
    @State private var hoveredPinnedExtensionID: String?
    @State private var extensionActionPopup: BrowserExtensionActionPopup?
    @State private var copyFeedbackTask: Task<Void, Never>?

    private var displayURL: String {
        guard let tab else {
            return BrowserStrings.newTabTitle
        }

        if showsFullURL {
            return BrowserURLDisplayFormatter.fullDisplayString(for: tab.urlString)
        }

        return BrowserURLDisplayFormatter.displayString(for: tab.urlString)
    }

    private var currentHost: String? {
        guard
            let urlString = tab?.urlString,
            let url = URL(string: urlString),
            let host = url.host,
            !host.isEmpty
        else {
            return nil
        }

        return BrowserURLDisplayFormatter.hostDisplayString(forHost: host)
    }

    private var pinnedExtensions: [BrowserExtension] {
        let extensionsByID = Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0) })
        return pinnedExtensionIDs.compactMap { id in
            guard let browserExtension = extensionsByID[id], browserExtension.isEnabled else {
                return nil
            }

            return browserExtension
        }
    }

    private var leftToolbarControls: some View {
        HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
            BrowserChromeControlButton(
                systemImageName: "arrow.backward",
                tooltipTitle: BrowserStrings.navigationBack,
                tooltipShortcut: goBackShortcut,
                isEnabled: canGoBack,
                pressEffect: .moveLeft,
                action: onGoBack
            )

            BrowserChromeControlButton(
                systemImageName: "arrow.forward",
                tooltipTitle: BrowserStrings.navigationForward,
                tooltipShortcut: goForwardShortcut,
                isEnabled: canGoForward,
                pressEffect: .moveRight,
                action: onGoForward
            )

            BrowserChromeControlButton(
                systemImageName: canStopLoading ? "xmark" : "arrow.clockwise",
                tooltipTitle: canStopLoading ? BrowserStrings.navigationStopLoading : BrowserStrings.navigationRefresh,
                tooltipShortcut: canStopLoading ? nil : reloadShortcut,
                isEnabled: canStopLoading || canReload,
                pressEffect: canStopLoading ? .compress : .rotateClockwise,
                action: canStopLoading ? onStopLoading : onReload
            )
        }
    }

    private var urlToolbarCluster: some View {
        HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
            copyToolbarButton

            urlToolbarButton
                .layoutPriority(1)
        }
    }

    private var copyToolbarButton: some View {
        BrowserChromeControlButton(
            systemImageName: didCopyURL ? "checkmark" : "link",
            tooltipTitle: BrowserStrings.tabCopyURLAction,
            tooltipShortcut: copyLinkShortcut,
            isEnabled: tab != nil,
            pressEffect: .compress,
            action: copyURL
        )
        .animation(BrowserChromeLayout.currentURLCopyIconAnimation, value: didCopyURL)
    }

    private var urlToolbarButton: some View {
        Button(action: onOpenSearch) {
            Text(displayURL)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BrowserChromePalette.currentURLText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
                .frame(height: BrowserChromeLayout.chromeButtonSize)
                .background {
                    RoundedRectangle(
                        cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                        style: .continuous
                    )
                    .fill(BrowserChromePalette.currentURLRow)
                }
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: BrowserChromeLayout.sidebarCurrentURLButtonCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(BrowserSidebarPressButtonStyle())
        .disabled(tab == nil)
        .frame(maxWidth: BrowserChromeLayout.siteToolbarURLButtonMaximumWidth)
        .background {
            BrowserWindowFrameReader(onFrameChange: onURLButtonFrameChange)
        }
        .contextMenu {
            BrowserSiteURLContextMenuContent(
                tab: tab,
                copyLinkShortcut: copyLinkShortcut,
                toggleBookmarksBarShortcut: toggleBookmarksBarShortcut,
                isToolbarPresented: true,
                showsFullURL: showsFullURL,
                isBookmarksBarVisible: isBookmarksBarVisible,
                onCopyURL: {
                    _ = onCopyURL()
                },
                onCaptureFullPage: {
                    _ = onCaptureFullPage()
                },
                onToggleToolbar: onToggleToolbar,
                onToggleShowsFullURL: onToggleShowsFullURL,
                onToggleBookmarksBar: onToggleBookmarksBar
            )
        }
    }

    private var rightToolbarControls: some View {
        HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
            ForEach(pinnedExtensions) { browserExtension in
                toolbarExtensionActionButton(
                    browserExtension: browserExtension,
                    isPinned: pinnedExtensionIDs.contains(browserExtension.id),
                    isHovered: hoveredPinnedExtensionID == browserExtension.id,
                    onHover: { hovering in
                        hoveredPinnedExtensionID = hovering ? browserExtension.id : nil
                    },
                    action: {
                        openExtensionFromToolbarButton(browserExtension.id)
                    }
                )
            }

            siteControlCenterButton
        }
    }

    private var siteControlCenterButton: some View {
        BrowserChromeControlButton(
            systemImageName: "slider.horizontal.3",
            tooltipTitle: BrowserStrings.siteControlCenterAction,
            tooltipShortcut: nil,
            isEnabled: tab != nil,
            pressEffect: .compress,
            action: { isSiteControlCenterPresented = true }
        )
        .popover(isPresented: $isSiteControlCenterPresented, arrowEdge: .top) {
            BrowserSiteControlCenterPopover(
                extensions: extensions,
                pinnedExtensionIDs: pinnedExtensionIDs,
                currentHost: currentHost,
                onManageExtensions: {
                    isSiteControlCenterPresented = false
                    onOpenExtensionsManager()
                },
                onAddExtension: {
                    isSiteControlCenterPresented = false
                    onOpenExtensionStore()
                },
                onSelectExtension: { extensionID in
                    let popup = onOpenExtension(extensionID)
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = popup
                    return popup
                },
                onOpenExtensionStore: { extensionID in
                    isSiteControlCenterPresented = false
                    onOpenExtensionStorePage(extensionID)
                },
                onOpenExtensionDetails: { extensionID in
                    isSiteControlCenterPresented = false
                    onOpenExtensionDetails(extensionID)
                },
                onRemoveExtension: { extensionID in
                    isSiteControlCenterPresented = false
                    onRemoveExtension(extensionID)
                },
                onToggleExtensionPinned: { extensionID in
                    onToggleExtensionPinned(extensionID)
                }
            )
            .onAppear(perform: onRefreshExtensions)
        }
        .popover(item: $extensionActionPopup, arrowEdge: .top) { popup in
            BrowserExtensionActionPopupView(popup: popup)
        }
    }

    private func toolbarExtensionActionButton(
        browserExtension: BrowserExtension,
        isPinned: Bool,
        isHovered: Bool,
        onHover: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
                    style: .continuous
                )
                .fill(isHovered ? BrowserChromePalette.rowHover : Color.clear)

                if let iconImage = browserExtension.iconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: BrowserChromeLayout.sidebarCurrentURLExtensionIconSize,
                            height: BrowserChromeLayout.sidebarCurrentURLExtensionIconSize
                        )
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(
                            size: BrowserChromeLayout.chromeButtonSymbolSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(BrowserChromePalette.secondaryText)
                }
            }
            .frame(
                width: BrowserChromeLayout.chromeButtonSize,
                height: BrowserChromeLayout.chromeButtonSize
            )
        }
        .buttonStyle(BrowserSidebarCloseButtonStyle())
        .contentShape(
            RoundedRectangle(
                cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
                style: .continuous
            )
        )
        .contextMenu {
            BrowserExtensionContextMenuContent(
                browserExtension: browserExtension,
                isPinned: isPinned,
                currentHost: currentHost,
                onSelectExtension: { extensionID in
                    openExtensionFromToolbarButton(extensionID)
                    return extensionActionPopup
                },
                onOpenExtensionStore: { extensionID in
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = nil
                    onOpenExtensionStorePage(extensionID)
                },
                onOpenExtensionDetails: { extensionID in
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = nil
                    onOpenExtensionDetails(extensionID)
                },
                onRemoveExtension: { extensionID in
                    isSiteControlCenterPresented = false
                    extensionActionPopup?.close()
                    extensionActionPopup = nil
                    onRemoveExtension(extensionID)
                },
                onToggleExtensionPinned: onToggleExtensionPinned
            )
        }
        .onHover(perform: onHover)
        .browserTooltip(
            title: browserExtension.name,
            shortcut: nil,
            placement: .belowLeading,
            isPresented: isHovered
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
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

    private func openExtensionFromToolbarButton(_ extensionID: String) {
        isSiteControlCenterPresented = false
        let popup = onOpenExtension(extensionID)
        extensionActionPopup?.close()
        extensionActionPopup = popup
    }
}
