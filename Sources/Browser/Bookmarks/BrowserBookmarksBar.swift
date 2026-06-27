import AppKit
import SwiftUI

// MARK: - BrowserBookmarksBar

struct BrowserBookmarksBar: View {
    // MARK: Internal

    let items: [BrowserBookmarkItem]
    let selectedTab: BrowserChromeModel.Tab?
    let isSelectedTabBookmarked: Bool
    let toggleBookmarkShortcut: BrowserKeyboardShortcut
    let toggleBookmarksBarShortcut: BrowserKeyboardShortcut
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let onOpenBookmark: (String) -> Void
    let onOpenBookmarks: ([String]) -> Void
    let onToggleSelectedTabBookmark: () -> Void
    let onRenameBookmark: (String, String) -> Bool
    let onEditBookmarkAddress: (String, String) -> Bool
    let onMoveBookmark: (String, String?) -> Bool
    let onCreateFolder: (String) -> String?
    let onCreateFolderAndMoveBookmark: (String, String) -> Bool
    let onDeleteBookmark: (String) -> Bool
    let onManageBookmarks: () -> Void
    let onHideBookmarksBar: () -> Void

    var canAddSelectedTab: Bool {
        guard let selectedTab else {
            return false
        }

        return !selectedTab.urlString.isEmpty
    }

    var selectedTabBookmarkTooltipTitle: String {
        isSelectedTabBookmarked ? BrowserStrings.bookmarksRemoveCurrentPage : BrowserStrings.bookmarksAddCurrentPage
    }

    var body: some View {
        HStack(spacing: BrowserChromeLayout.bookmarksBarControlSpacing) {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        BrowserWindowDragRegion()
                            .frame(
                                width: max(proxy.size.width, 0),
                                height: BrowserChromeLayout.bookmarksBarHeight
                            )
                            .contextMenu {
                                barContextMenu
                            }

                        HStack(spacing: BrowserChromeLayout.bookmarksBarItemSpacing) {
                            ForEach(items) { item in
                                BrowserBookmarksBarItem(
                                    item: item,
                                    folderDestinations: folderDestinations,
                                    isRootItem: rootItemIDs.contains(item.id),
                                    onOpenBookmark: onOpenBookmark,
                                    onOpenBookmarks: onOpenBookmarks,
                                    onRenameBookmark: onRenameBookmark,
                                    onEditBookmarkAddress: onEditBookmarkAddress,
                                    onMoveBookmark: onMoveBookmark,
                                    onCreateFolderAndMoveBookmark: onCreateFolderAndMoveBookmark,
                                    onDeleteBookmark: onDeleteBookmark,
                                    onManageBookmarks: onManageBookmarks
                                )
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, BrowserChromeLayout.bookmarksBarHorizontalPadding)
                    }
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
            }
            .frame(height: BrowserChromeLayout.bookmarksBarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            BrowserWindowDragRegion()

            HStack(spacing: BrowserChromeLayout.bookmarksBarControlSpacing) {
                BrowserBookmarksBarIconButton(
                    systemImageName: isSelectedTabBookmarked ? "star.fill" : "star",
                    tooltipTitle: selectedTabBookmarkTooltipTitle,
                    tooltipShortcut: toggleBookmarkShortcut,
                    isEnabled: canAddSelectedTab,
                    isSelected: isSelectedTabBookmarked,
                    action: onToggleSelectedTabBookmark
                )
                .opacity(canAddSelectedTab ? 1 : 0.42)
            }
            .padding(.trailing, BrowserChromeLayout.bookmarksBarHorizontalPadding)
        }
        .frame(height: BrowserChromeLayout.bookmarksBarHeight)
        .contextMenu {
            barContextMenu
        }
        .background {
            ZStack {
                BrowserChromeBackgroundView(mode: chromeBackgroundMode)
                    .clipShape(barShape)
                BrowserWindowDragRegion()
            }
        }
        .clipShape(barShape)
        .browserWindowDragGesture()
    }

    // MARK: Private

    private var folderDestinations: [BrowserBookmarkFolderDestination] {
        BrowserBookmarkFolderDestination.destinations(in: items)
    }

    private var rootItemIDs: Set<String> {
        Set(items.map(\.id))
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.bookmarksBarCornerRadius, style: .continuous)
    }

    @ViewBuilder private var barContextMenu: some View {
        Button(BrowserStrings.bookmarksNewFolderAction) {
            promptAndCreateRootFolder()
        }
        Button(BrowserStrings.bookmarksManageAction, action: onManageBookmarks)
        Divider()
        Button(BrowserStrings.bookmarksHideBarAction, action: onHideBookmarksBar)
            .browserKeyboardShortcut(toggleBookmarksBarShortcut)
    }

    private func promptAndCreateRootFolder() {
        guard
            let title = promptForText(
                title: BrowserStrings.bookmarksNewFolderPromptTitle,
                defaultValue: BrowserStrings.bookmarksUntitledFolder
            )
        else {
            return
        }

        _ = onCreateFolder(title)
    }
}

// MARK: - BrowserBookmarkFolderDestination

private struct BrowserBookmarkFolderDestination: Identifiable, Equatable {
    let id: String
    let title: String

    static func destinations(in items: [BrowserBookmarkItem]) -> [BrowserBookmarkFolderDestination] {
        items.flatMap { item -> [BrowserBookmarkFolderDestination] in
            guard item.isFolder else {
                return []
            }

            let destination = BrowserBookmarkFolderDestination(id: item.id, title: item.displayTitle)
            return [destination] + destinations(in: item.children).map {
                BrowserBookmarkFolderDestination(id: $0.id, title: "\(item.displayTitle) / \($0.title)")
            }
        }
    }
}

// MARK: - BrowserBookmarksBarItem

private struct BrowserBookmarksBarItem: View {
    // MARK: Internal

    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let item: BrowserBookmarkItem
    let folderDestinations: [BrowserBookmarkFolderDestination]
    let isRootItem: Bool
    let onOpenBookmark: (String) -> Void
    let onOpenBookmarks: ([String]) -> Void
    let onRenameBookmark: (String, String) -> Bool
    let onEditBookmarkAddress: (String, String) -> Bool
    let onMoveBookmark: (String, String?) -> Bool
    let onCreateFolderAndMoveBookmark: (String, String) -> Bool
    let onDeleteBookmark: (String) -> Bool
    let onManageBookmarks: () -> Void

    var cachedFavicon: NSImage? {
        faviconCache.image(for: item.faviconURL)
    }

    var tooltipCaption: String? {
        item.hostDisplayString
    }

    var body: some View {
        if item.isFolder {
            folderMenu
        } else {
            bookmarkButton
        }
    }

    var bookmarkButton: some View {
        Button {
            guard let urlString = item.urlString else {
                return
            }

            onOpenBookmark(urlString)
        } label: {
            labelContent(systemImageName: "globe")
        }
        .buttonStyle(BrowserSidebarPressButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onDisappear {
            isHovered = false
        }
        .task(id: item.faviconURL) {
            await faviconCache.loadImageIfNeeded(from: item.faviconURL)
        }
        .contextMenu {
            bookmarkContextMenu
        }
    }

    var folderMenu: some View {
        Menu {
            ForEach(item.children) { child in
                BrowserBookmarksMenuItem(item: child, onOpenBookmark: onOpenBookmark)
            }
        } label: {
            labelContent(
                systemImageName: "folder",
                showsHoverBackground: false,
                appliesItemChrome: false
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(BrowserSidebarPressButtonStyle())
        .padding(.horizontal, BrowserChromeLayout.bookmarksBarItemHorizontalPadding)
        .frame(
            maxWidth: BrowserChromeLayout.bookmarksBarItemMaximumWidth,
            minHeight: BrowserChromeLayout.bookmarksBarItemHeight,
            maxHeight: BrowserChromeLayout.bookmarksBarItemHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius, style: .continuous)
                .fill(isHovered ? BrowserChromePalette.rowHover : .clear)
        }
        .contentShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onDisappear {
            isHovered = false
        }
        .contextMenu {
            folderContextMenu
        }
    }

    @ViewBuilder var bookmarkContextMenu: some View {
        Button(BrowserStrings.bookmarksRenameAction) {
            promptAndRename()
        }
        Button(BrowserStrings.bookmarksEditAddressAction) {
            promptAndEditAddress()
        }
        moveMenu
        Divider()
        Button(BrowserStrings.bookmarksDeleteAction, role: .destructive) {
            _ = onDeleteBookmark(item.id)
        }
        Divider()
        Button(BrowserStrings.bookmarksManageAction, action: onManageBookmarks)
    }

    @ViewBuilder var folderContextMenu: some View {
        Button(BrowserStrings.bookmarksRenameAction) {
            promptAndRename()
        }
        Button(BrowserStrings.bookmarksOpenAllAction(count: item.flattenedBookmarkURLStrings.count)) {
            onOpenBookmarks(item.flattenedBookmarkURLStrings)
        }
        .disabled(item.flattenedBookmarkURLStrings.isEmpty)
        Divider()
        Button(BrowserStrings.bookmarksDeleteAction, role: .destructive) {
            _ = onDeleteBookmark(item.id)
        }
        Divider()
        Button(BrowserStrings.bookmarksManageAction, action: onManageBookmarks)
    }

    var moveMenu: some View {
        Menu(BrowserStrings.bookmarksMoveToAction) {
            if !isRootItem {
                Button(BrowserStrings.bookmarksBarDestination) {
                    _ = onMoveBookmark(item.id, nil)
                }
            }
            ForEach(folderDestinations.filter { $0.id != item.id }) { destination in
                Button(destination.title) {
                    _ = onMoveBookmark(item.id, destination.id)
                }
            }
            Divider()
            Button(BrowserStrings.bookmarksNewFolderAction) {
                promptAndCreateFolder()
            }
        }
    }

    func labelContent(
        systemImageName: String,
        showsHoverBackground: Bool = true,
        appliesItemChrome: Bool = true
    ) -> some View {
        HStack(spacing: BrowserChromeLayout.bookmarksBarLabelSpacing) {
            if let cachedFavicon {
                Image(nsImage: cachedFavicon)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: BrowserChromeLayout.bookmarksBarIconSize,
                        height: BrowserChromeLayout.bookmarksBarIconSize
                    )
            } else {
                Image(systemName: systemImageName)
                    .font(.system(size: BrowserChromeLayout.bookmarksBarIconSize, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .frame(
                        width: BrowserChromeLayout.bookmarksBarIconSize,
                        height: BrowserChromeLayout.bookmarksBarIconSize
                    )
            }

            Text(item.displayTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, appliesItemChrome ? BrowserChromeLayout.bookmarksBarItemHorizontalPadding : 0)
        .frame(
            maxWidth: appliesItemChrome ? BrowserChromeLayout.bookmarksBarItemMaximumWidth : nil,
            minHeight: appliesItemChrome ? BrowserChromeLayout.bookmarksBarItemHeight : nil,
            maxHeight: appliesItemChrome ? BrowserChromeLayout.bookmarksBarItemHeight : nil,
            alignment: .leading
        )
        .background {
            if showsHoverBackground {
                RoundedRectangle(cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius, style: .continuous)
                    .fill(isHovered ? BrowserChromePalette.rowHover : .clear)
            }
        }
        .contentShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius, style: .continuous)
        )
        .browserTooltip(
            title: item.displayTitle,
            caption: tooltipCaption,
            shortcut: nil,
            isPresented: isHovered
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
    }

    func promptAndRename() {
        guard
            let title = promptForText(
                title: BrowserStrings.bookmarksRenamePromptTitle,
                defaultValue: item.displayTitle
            )
        else {
            return
        }

        _ = onRenameBookmark(item.id, title)
    }

    func promptAndEditAddress() {
        guard
            let urlString = item.urlString,
            let updatedURLString = promptForText(
                title: BrowserStrings.bookmarksEditAddressPromptTitle,
                defaultValue: urlString
            )
        else {
            return
        }

        _ = onEditBookmarkAddress(item.id, updatedURLString)
    }

    func promptAndCreateFolder() {
        guard
            let title = promptForText(
                title: BrowserStrings.bookmarksNewFolderPromptTitle,
                defaultValue: BrowserStrings.bookmarksUntitledFolder
            )
        else {
            return
        }

        _ = onCreateFolderAndMoveBookmark(title, item.id)
    }

    // MARK: Private

    @State private var isHovered = false
}

// MARK: - BrowserBookmarksBarIconButton

private struct BrowserBookmarksBarIconButton: View {
    // MARK: Internal

    let systemImageName: String
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    let isEnabled: Bool
    let isSelected: Bool
    let action: () -> Void

    var foregroundColor: Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonDisabledForeground
        }

        if isPressed || isSelected {
            return BrowserChromePalette.primaryText
        }

        return BrowserChromePalette.secondaryText
    }

    var backgroundColor: Color {
        guard isEnabled, isHovered else {
            return .clear
        }

        return BrowserChromePalette.rowHover
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: BrowserChromeLayout.bookmarksBarIconSize, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .scaleEffect(isPressed ? 0.9 : 1)
                .frame(
                    width: BrowserChromeLayout.bookmarksBarControlSize,
                    height: BrowserChromeLayout.bookmarksBarControlSize
                )
                .background {
                    RoundedRectangle(
                        cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius,
                        style: .continuous
                    )
                    .fill(backgroundColor)
                    .scaleEffect(isPressed ? 0.95 : 1)
                }
        }
        .buttonStyle(BrowserSidebarPressTrackingButtonStyle { isPressed in
            self.isPressed = isEnabled && isPressed
        })
        .disabled(!isEnabled)
        .contentShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.bookmarksBarItemCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isEnabled) { _, isEnabled in
            if !isEnabled {
                isHovered = false
                isPressed = false
            }
        }
        .onDisappear {
            isHovered = false
            isPressed = false
        }
        .accessibilityLabel(tooltipTitle)
        .browserTooltip(title: tooltipTitle, shortcut: tooltipShortcut, isPresented: isHovered && isEnabled)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var isPressed = false
}

// MARK: - BrowserBookmarksMenuItem

private struct BrowserBookmarksMenuItem: View {
    @EnvironmentObject var faviconCache: BrowserFaviconCache

    let item: BrowserBookmarkItem
    let onOpenBookmark: (String) -> Void

    var cachedFavicon: NSImage? {
        faviconCache.image(for: item.faviconURL)
    }

    var menuFavicon: NSImage? {
        cachedFavicon.flatMap {
            BrowserImageThumbnailer.resizedImage($0, fitting: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize)
        }
    }

    var body: some View {
        menuContent
            .task(id: item.faviconURL) {
                await faviconCache.loadImageIfNeeded(from: item.faviconURL)
            }
    }

    @ViewBuilder var menuContent: some View {
        if item.isFolder {
            Menu {
                ForEach(item.children) { child in
                    BrowserBookmarksMenuItem(item: child, onOpenBookmark: onOpenBookmark)
                }
            } label: {
                Label {
                    Text(item.displayTitle)
                } icon: {
                    Image(systemName: "folder")
                        .font(.system(size: BrowserChromeLayout.bookmarksBarIconSize, weight: .medium))
                        .frame(
                            width: BrowserChromeLayout.bookmarksBarIconSize,
                            height: BrowserChromeLayout.bookmarksBarIconSize
                        )
                }
            }
        } else {
            Button {
                guard let urlString = item.urlString else {
                    return
                }

                onOpenBookmark(urlString)
            } label: {
                Label {
                    Text(item.displayTitle)
                } icon: {
                    if let menuFavicon {
                        Image(nsImage: menuFavicon)
                            .frame(
                                width: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize,
                                height: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize
                            )
                            .clipped()
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize, weight: .medium))
                            .frame(
                                width: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize,
                                height: BrowserChromeLayout.bookmarksFolderMenuSiteIconSize
                            )
                    }
                }
            }
        }
    }
}

// MARK: - Prompt helpers

@MainActor private func promptForText(title: String, defaultValue: String) -> String? {
    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    textField.stringValue = defaultValue

    let alert = NSAlert()
    alert.messageText = title
    alert.accessoryView = textField
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else {
        return nil
    }

    let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}
