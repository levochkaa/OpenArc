import AppKit
import SwiftUI

// MARK: - BrowserSidebarRow

struct BrowserSidebarRow: View {
    // MARK: Internal

    let tab: BrowserChromeModel.Tab
    let copyLinkDescriptor: BrowserCommandDescriptor
    let archiveTabDescriptor: BrowserCommandDescriptor
    let isSelected: Bool
    let isMultiSelected: Bool
    let isRenaming: Bool
    let canArchiveTabsBelow: Bool
    let canCreateFolderFromSelection: Bool
    let indentLevel: Int
    let isSidebarResizing: Bool
    let interactionResetID: Int
    let onSelect: () -> Void
    let onCopyLink: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onCreateFolderFromSelection: () -> Void
    let onClose: () -> Void
    let onArchiveTabsBelow: () -> Void

    @State var isRowHovered = false
    @State var isCloseHovered = false
    @State var isRowPressed = false
    @State var draftTitle = ""
    @State var initialRenameTitle = ""

    var closeButtonBackgroundColor: Color {
        isCloseHovered ? BrowserChromePalette.rowCloseHover : .clear
    }

    var closeButtonReservedWidth: CGFloat {
        BrowserChromeLayout.sidebarCloseButtonSize + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    var showsCloseButton: Bool {
        isRowHovered && !isRenaming
    }

    var hasUserTitleOverride: Bool {
        let trimmedUserTitleOverride = tab.userTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmedUserTitleOverride.isEmpty
    }

    var renameTooltipCaption: String? {
        BrowserURLDisplayFormatter.displayString(for: tab.urlString)
    }

    var rowBackgroundColor: Color {
        if isSelected {
            return BrowserChromePalette.rowSelected
        }

        if isMultiSelected {
            return BrowserChromePalette.rowSelected.opacity(0.82)
        }

        return isRowHovered ? BrowserChromePalette.rowHover : .clear
    }

    var rowBackgroundLeadingInset: CGFloat {
        CGFloat(max(indentLevel, 0)) * BrowserChromeLayout.sidebarPinnedFolderTabIndent
    }

    var body: some View {
        rowInteractionSurface
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                if isRenaming {
                    isRowHovered = hovering
                    if !hovering {
                        isCloseHovered = false
                    }
                    return
                }

                isRowHovered = hovering
                if !hovering {
                    isCloseHovered = false
                }
            }
            .onAppear {
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
            }
            .onChange(of: isRenaming) { _, isRenaming in
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
                if isRenaming {
                    isCloseHovered = false
                    isRowPressed = false
                }
            }
            .onChange(of: isSidebarResizing) { _, isSidebarResizing in
                guard isSidebarResizing else {
                    return
                }

                resetTransientInteractionState()
            }
            .onChange(of: interactionResetID) { _, _ in
                resetTransientInteractionState()
            }
            .onDisappear {
                resetTransientInteractionState()
            }
            .contextMenu {
                let sharingItems = makeSharingItems()

                tabContextMenuItems(sharingItems: sharingItems)
            }
    }

    var rowInteractionSurface: some View {
        ZStack(alignment: .trailing) {
            rowSurface

            rowSelectionButton
                .allowsHitTesting(!isRenaming)

            closeButtonOverlay
                .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        }
        .scaleEffect(isRowPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isRowPressed)
    }

    var rowSelectionButton: some View {
        Button(action: handlePrimaryTap) {
            Color.clear
                .frame(
                    maxWidth: .infinity,
                    minHeight: BrowserChromeLayout.sidebarRowHeight,
                    maxHeight: BrowserChromeLayout.sidebarRowHeight
                )
                .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        }
        .buttonStyle(
            BrowserSidebarPressTrackingButtonStyle { isPressed in
                isRowPressed = isPressed
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    handlePrimaryDoubleTap()
                }
        )
    }

    var rowSurface: some View {
        let spacing = BrowserChromeLayout.sidebarRowContentSpacing

        return HStack(spacing: 0) {
            BrowserFaviconView(url: tab.faviconURL)
            Spacer(minLength: 0)
                .frame(width: spacing)

            if isRenaming {
                BrowserSidebarTitleTextField(
                    text: $draftTitle,
                    isFocused: isRenaming,
                    onSubmit: submitRename,
                    onCancel: cancelRename,
                    onBlur: blurRename
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: 1)
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.trailing, showsCloseButton ? closeButtonReservedWidth : 0)
        .contentShape(Rectangle())
        .browserTooltip(
            title: tab.displayTitle,
            caption: renameTooltipCaption,
            shortcut: nil,
            isPresented: isRowHovered
                && !isCloseHovered
                && !isRenaming
                && !isSidebarResizing
        )
        .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
        .padding(.leading, rowBackgroundLeadingInset)
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: BrowserChromeLayout.sidebarRowHeight,
            maxHeight: BrowserChromeLayout.sidebarRowHeight,
            alignment: .leading
        )
        .background(backgroundShape)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
    }

    var closeButtonOverlay: some View {
        ZStack(alignment: .trailing) {
            Button(action: onClose) {
                ZStack {
                    RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
                        .fill(closeButtonBackgroundColor)

                    Image(systemName: "xmark")
                        .font(.system(size: BrowserChromeLayout.sidebarCloseSymbolSize, weight: .bold))
                        .foregroundStyle(BrowserChromePalette.rowCloseForeground)
                }
                .frame(
                    width: BrowserChromeLayout.sidebarCloseButtonSize,
                    height: BrowserChromeLayout.sidebarCloseButtonSize
                )
            }
            .buttonStyle(BrowserSidebarCloseButtonStyle())
            .contentShape(
                RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
            )
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                isCloseHovered = hovering
            }
            .opacity(showsCloseButton ? 1 : 0)
            .allowsHitTesting(showsCloseButton)
        }
        .frame(
            width: closeButtonReservedWidth,
            height: BrowserChromeLayout.sidebarCloseButtonSize,
            alignment: .trailing
        )
        .browserTooltip(
            title: archiveTabDescriptor.helpTitle,
            shortcut: isSelected ? archiveTabDescriptor.shortcut : nil,
            isPresented: showsCloseButton && isCloseHovered && !isSidebarResizing
        )
    }

    var backgroundShape: some View {
        HStack(spacing: 0) {
            if rowBackgroundLeadingInset > 0 {
                Color.clear
                    .frame(width: rowBackgroundLeadingInset)
            }

            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
                .fill(rowBackgroundColor)
        }
    }

    @ViewBuilder var copyLinkMenuItem: some View {
        if isSelected {
            Button(copyLinkDescriptor.menuTitle, action: onCopyLink)
                .browserKeyboardShortcut(copyLinkDescriptor.shortcut)
        } else {
            Button(copyLinkDescriptor.menuTitle, action: onCopyLink)
        }
    }

    @ViewBuilder var archiveTabMenuItem: some View {
        if isSelected {
            Button(archiveTabDescriptor.menuTitle, role: .destructive, action: onClose)
                .browserKeyboardShortcut(archiveTabDescriptor.shortcut)
        } else {
            Button(archiveTabDescriptor.menuTitle, role: .destructive, action: onClose)
        }
    }

    @ViewBuilder func tabContextMenuItems(sharingItems: [Any]) -> some View {
        copyLinkMenuItem
        shareMenuItem(sharingItems: sharingItems)
        if canCreateFolderFromSelection {
            Button(BrowserStrings.pinnedTabFolderNewAction, action: onCreateFolderFromSelection)
        }
        Button(BrowserStrings.tabRenameAction, action: beginRename)
        Divider()
        archiveTabMenuItem
        Button(
            BrowserStrings.tabArchiveTabsBelowAction,
            role: .destructive,
            action: onArchiveTabsBelow
        )
        .disabled(!canArchiveTabsBelow)
    }

    func shareMenuItem(sharingItems: [Any]) -> some View {
        BrowserSharingServicesMenu(
            sharingItems: sharingItems,
            subject: tab.displayTitle
        )
    }

    // MARK: Private

    private var hasRenameChanged: Bool {
        normalizedRenameTitle(draftTitle) != normalizedRenameTitle(initialRenameTitle)
    }

    private func makeSharingItems() -> [Any] {
        if let pageURL = tab.pageURL {
            return [pageURL]
        }

        return [NSString(string: tab.urlString)]
    }

    private func handlePrimaryTap() {
        if isSelected {
            beginRename()
            return
        }

        onSelect()
    }

    private func handlePrimaryDoubleTap() {
        if !isSelected {
            onSelect()
        }

        beginRename()
    }

    private func beginRename() {
        let title = tab.userTitleOverride ?? tab.displayTitle
        draftTitle = title
        initialRenameTitle = title
        onBeginRename()
    }

    private func submitRename() {
        if hasRenameChanged {
            onCommitRename(draftTitle)
        } else {
            onCancelRename()
        }
    }

    private func blurRename() {
        guard hasRenameChanged else {
            return
        }

        onCommitRename(draftTitle)
    }

    private func cancelRename() {
        let title = tab.userTitleOverride ?? tab.displayTitle
        draftTitle = title
        initialRenameTitle = title
        onCancelRename()
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isCloseHovered = false
        isRowPressed = false
    }

    private func syncDraftTitleIfNeeded(isRenaming: Bool) {
        guard isRenaming else {
            return
        }

        let title = tab.userTitleOverride ?? tab.displayTitle
        draftTitle = title
        initialRenameTitle = title
    }

    private func normalizedRenameTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - BrowserSidebarPinnedFolderRowView

struct BrowserSidebarPinnedFolderRowView: View {
    // MARK: Internal

    let folder: BrowserChromeModel.PinnedTabFolder
    let isRenaming: Bool
    let indentLevel: Int
    let isSidebarResizing: Bool
    let interactionResetID: Int
    let onToggleExpanded: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onChangeIcon: (String?) -> Void

    @State var isRowHovered = false
    @State var isRowPressed = false
    @State var draftTitle = ""
    @State var initialRenameTitle = ""

    var rowBackgroundLeadingInset: CGFloat {
        CGFloat(max(indentLevel, 0)) * BrowserChromeLayout.sidebarPinnedFolderTabIndent
    }

    var body: some View {
        rowInteractionSurface
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                isRowHovered = hovering
            }
            .onAppear {
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
            }
            .onChange(of: isRenaming) { _, isRenaming in
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
                if isRenaming {
                    isRowPressed = false
                }
            }
            .onChange(of: isSidebarResizing) { _, isSidebarResizing in
                guard isSidebarResizing else {
                    return
                }

                resetTransientInteractionState()
            }
            .onChange(of: interactionResetID) { _, _ in
                resetTransientInteractionState()
            }
            .onDisappear {
                resetTransientInteractionState()
            }
            .contextMenu {
                menuItems
            }
    }

    var rowInteractionSurface: some View {
        ZStack {
            rowSurface

            Button(action: onToggleExpanded) {
                Color.clear
                    .frame(
                        maxWidth: .infinity,
                        minHeight: BrowserChromeLayout.sidebarRowHeight,
                        maxHeight: BrowserChromeLayout.sidebarRowHeight
                    )
                    .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
            }
            .buttonStyle(
                BrowserSidebarPressTrackingButtonStyle { isPressed in
                    isRowPressed = isPressed
                }
            )
            .allowsHitTesting(!isRenaming)
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        beginRename()
                    }
            )
        }
        .scaleEffect(isRowPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isRowPressed)
    }

    var rowSurface: some View {
        HStack(spacing: BrowserChromeLayout.sidebarRowContentSpacing) {
            BrowserPinnedTabFolderIcon(
                systemImageName: folder.systemImageName,
                isExpanded: folder.isExpanded
            )

            if isRenaming {
                BrowserSidebarTitleTextField(
                    text: $draftTitle,
                    isFocused: isRenaming,
                    onSubmit: submitRename,
                    onCancel: cancelRename,
                    onBlur: blurRename
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: 1)
            } else {
                Text(folder.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
        .padding(.leading, rowBackgroundLeadingInset)
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: BrowserChromeLayout.sidebarRowHeight,
            maxHeight: BrowserChromeLayout.sidebarRowHeight,
            alignment: .leading
        )
        .background(backgroundShape)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
    }

    var backgroundShape: some View {
        HStack(spacing: 0) {
            if rowBackgroundLeadingInset > 0 {
                Color.clear
                    .frame(width: rowBackgroundLeadingInset)
            }

            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
                .fill(isRowHovered ? BrowserChromePalette.rowHover : Color.clear)
        }
    }

    @ViewBuilder var menuItems: some View {
        Button(BrowserStrings.pinnedTabFolderRenameAction, action: beginRename)
        Menu(BrowserStrings.pinnedTabFolderChangeIconAction) {
            Button(BrowserStrings.pinnedTabFolderNoIconAction) {
                onChangeIcon(nil)
            }
            Divider()
            ForEach(BrowserSpaceIconCatalog.systemImageNames, id: \.self) { systemImageName in
                Button {
                    onChangeIcon(systemImageName)
                } label: {
                    Label(
                        systemImageName,
                        systemImage: folder.systemImageName == systemImageName ? "checkmark" : systemImageName
                    )
                }
            }
        }
    }

    // MARK: Private

    private var hasRenameChanged: Bool {
        normalizedRenameTitle(draftTitle) != normalizedRenameTitle(initialRenameTitle)
    }

    private func beginRename() {
        let title = folder.title
        draftTitle = title
        initialRenameTitle = title
        onBeginRename()
    }

    private func submitRename() {
        if hasRenameChanged {
            onCommitRename(draftTitle)
        } else {
            onCancelRename()
        }
    }

    private func blurRename() {
        guard hasRenameChanged else {
            return
        }

        onCommitRename(draftTitle)
    }

    private func cancelRename() {
        draftTitle = folder.title
        initialRenameTitle = folder.title
        onCancelRename()
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isRowPressed = false
    }

    private func syncDraftTitleIfNeeded(isRenaming: Bool) {
        guard isRenaming else {
            return
        }

        draftTitle = folder.title
        initialRenameTitle = folder.title
    }

    private func normalizedRenameTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - BrowserPinnedTabFolderIcon

struct BrowserPinnedTabFolderIcon: View {
    let systemImageName: String?
    let isExpanded: Bool

    var body: some View {
        ZStack {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: BrowserChromeLayout.sidebarPinnedFolderIconSize, weight: .semibold))
                .foregroundStyle(Color.yellow.opacity(0.88))
                .frame(
                    width: BrowserChromeLayout.sidebarPinnedFolderIconSize,
                    height: BrowserChromeLayout.sidebarPinnedFolderIconSize
                )

            if let systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(
                        size: BrowserChromeLayout.sidebarPinnedFolderBadgeIconSize,
                        weight: .bold
                    ))
                    .foregroundStyle(Color.black.opacity(0.78))
                    .offset(y: 1)
            }
        }
        .frame(
            width: BrowserChromeLayout.sidebarPinnedFolderIconSize,
            height: BrowserChromeLayout.sidebarPinnedFolderIconSize
        )
    }
}

// MARK: - BrowserSharingServicesMenu

struct BrowserSharingServicesMenu: View {
    let sharingItems: [Any]
    let subject: String

    var body: some View {
        Menu(BrowserStrings.tabShareAction) {
            let sharingServices = BrowserShareMenuServiceProvider.sharingServices(for: sharingItems)

            ForEach(Array(sharingServices.enumerated()), id: \.offset) { _, service in
                Button {
                    service.subject = subject
                    service.perform(withItems: sharingItems)
                } label: {
                    Label {
                        Text(service.menuItemTitle)
                    } icon: {
                        Image(nsImage: service.image)
                    }
                }
            }
        }
    }
}

// MARK: - BrowserShareMenuServiceProvider

enum BrowserShareMenuServiceProvider {
    // MARK: Internal

    static func sharingServices(for items: [Any]) -> [NSSharingService] {
        let readingListMenuTitle = NSSharingService(named: .addToSafariReadingList)?.menuItemTitle

        return legacySharingServices(for: items).filter { service in
            guard let readingListMenuTitle else {
                return true
            }

            return service.menuItemTitle != readingListMenuTitle
        }
    }

    // MARK: Private

    private static func legacySharingServices(for items: [Any]) -> [NSSharingService] {
        let selector = NSSelectorFromString("sharingServicesForItems:")

        guard NSSharingService.responds(to: selector),
              let result = NSSharingService.perform(selector, with: items as NSArray)?.takeUnretainedValue()
        else {
            return []
        }

        return result as? [NSSharingService] ?? []
    }
}
