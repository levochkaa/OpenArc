import AppKit
import QuartzCore
import SwiftUI

struct BrowserSidebarRow: View {
    let tab: BrowserChromeModel.Tab
    let copyLinkDescriptor: BrowserCommandDescriptor
    let archiveTabDescriptor: BrowserCommandDescriptor
    let isSelected: Bool
    let isRenaming: Bool
    let canArchiveTabsBelow: Bool
    let isSidebarResizing: Bool
    let interactionResetID: Int
    let onSelect: () -> Void
    let onCopyLink: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onClose: () -> Void
    let onArchiveTabsBelow: () -> Void

    @State var isRowHovered = false
    @State var isCloseHovered = false
    @State var isRowPressed = false
    @State var draftTitle = ""

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
                copyLinkMenuItem
                shareMenuItem
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
        Button(action: onSelect) {
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
                    beginRename()
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
                    onSubmit: commitRename,
                    onCancel: cancelRename,
                    onBlur: commitRename
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
            caption: BrowserStrings.tabRenameTooltipCaption,
            shortcut: nil,
            isPresented: isRowHovered && !isCloseHovered && !isRenaming && !isSidebarResizing
        )
        .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
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

    var closeButtonBackgroundColor: Color {
        isCloseHovered ? BrowserChromePalette.rowCloseHover : .clear
    }

    var closeButtonReservedWidth: CGFloat {
        BrowserChromeLayout.sidebarCloseButtonSize + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    var showsCloseButton: Bool {
        isRowHovered && !isRenaming
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
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
            .fill(
                isSelected
                    ? BrowserChromePalette.rowSelected
                    : (isRowHovered ? BrowserChromePalette.rowHover : Color.clear)
            )
    }

    private func beginRename() {
        draftTitle = tab.userTitleOverride ?? tab.displayTitle
        onBeginRename()
    }

    private func commitRename() {
        onCommitRename(draftTitle)
    }

    private func cancelRename() {
        draftTitle = tab.userTitleOverride ?? tab.displayTitle
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

        draftTitle = tab.userTitleOverride ?? tab.displayTitle
    }

    @ViewBuilder
    var copyLinkMenuItem: some View {
        if isSelected {
            Button(copyLinkDescriptor.menuTitle, action: onCopyLink)
                .browserKeyboardShortcut(copyLinkDescriptor.shortcut)
        } else {
            Button(copyLinkDescriptor.menuTitle, action: onCopyLink)
        }
    }

    @ViewBuilder
    var archiveTabMenuItem: some View {
        if isSelected {
            Button(archiveTabDescriptor.menuTitle, role: .destructive, action: onClose)
                .browserKeyboardShortcut(archiveTabDescriptor.shortcut)
        } else {
            Button(archiveTabDescriptor.menuTitle, role: .destructive, action: onClose)
        }
    }

    @ViewBuilder
    var shareMenuItem: some View {
        let sharingServices = BrowserShareMenuServiceProvider.sharingServices(for: sharingItems)

        if !sharingServices.isEmpty {
            Menu(BrowserStrings.tabShareAction) {
                ForEach(Array(sharingServices.enumerated()), id: \.offset) { _, service in
                    Button {
                        service.subject = tab.displayTitle
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

    var sharingItems: [Any] {
        if let pageURL = tab.pageURL {
            return [pageURL]
        }

        return [NSString(string: tab.urlString)]
    }
}
enum BrowserShareMenuServiceProvider {
    static func sharingServices(for items: [Any]) -> [NSSharingService] {
        let readingListMenuTitle = NSSharingService(named: .addToSafariReadingList)?.menuItemTitle

        return legacySharingServices(for: items).filter { service in
            guard let readingListMenuTitle else {
                return true
            }

            return service.menuItemTitle != readingListMenuTitle
        }
    }

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
