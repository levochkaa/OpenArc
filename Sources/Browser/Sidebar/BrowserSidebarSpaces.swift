import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSpaceIconCatalog

enum BrowserSpaceIconCatalog {
    static let systemImageNames = [
        "square.grid.2x2",
        "briefcase",
        "house",
        "person",
        "book",
        "star",
        "hammer",
        "paintbrush",
        "terminal",
        "globe",
        "bolt",
        "heart",
    ]
}

// MARK: - BrowserSidebarSpaceHeaderRow

struct BrowserSidebarSpaceHeaderRow: View {
    // MARK: Internal

    let space: BrowserChromeModel.Space
    let isRenaming: Bool
    let isCollapsed: Bool
    let hasPinnedTabs: Bool
    let isSidebarResizing: Bool
    let interactionResetID: Int
    let onToggleCollapsed: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onChangeIcon: (String) -> Void
    let canDelete: Bool
    let onDelete: () -> Void

    @State var isRowHovered = false
    @State var isMenuHovered = false
    @State var isRowPressed = false
    @State var draftTitle = ""

    var leadingSystemImageName: String {
        isShowingDisclosure ? "chevron.right" : space.systemImageName
    }

    var leadingSymbolColor: Color {
        isShowingDisclosure ? BrowserChromePalette.secondaryText : BrowserChromePalette.primaryText
    }

    var leadingSymbolRotation: Angle {
        isShowingDisclosure && !isCollapsed ? .degrees(90) : .zero
    }

    var isShowingDisclosure: Bool {
        hasPinnedTabs && isRowHovered && !isRenaming
    }

    var menuButtonReservedWidth: CGFloat {
        BrowserChromeLayout.sidebarCloseButtonSize + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    var showsMenuButton: Bool {
        isRowHovered && !isRenaming
    }

    var body: some View {
        rowInteractionSurface
            .onHover { hovering in
                guard !isSidebarResizing else {
                    return
                }

                isRowHovered = hovering
                if !hovering {
                    isMenuHovered = false
                }
            }
            .onAppear {
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
            }
            .onChange(of: isRenaming) { _, isRenaming in
                syncDraftTitleIfNeeded(isRenaming: isRenaming)
                if isRenaming {
                    isMenuHovered = false
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
        ZStack(alignment: .trailing) {
            rowSurface

            rowSelectionButton
                .allowsHitTesting(!isRenaming)

            menuButtonOverlay
                .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        }
        .scaleEffect(isRowPressed ? BrowserChromeLayout.sidebarButtonPressedScale : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isRowPressed)
    }

    var rowSelectionButton: some View {
        Button(action: performPrimaryAction) {
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
    }

    var rowSurface: some View {
        HStack(spacing: 0) {
            Image(systemName: leadingSystemImageName)
                .font(.system(size: BrowserChromeLayout.sidebarNewTabSymbolSize, weight: .semibold))
                .foregroundStyle(leadingSymbolColor)
                .rotationEffect(leadingSymbolRotation)
                .animation(.easeInOut(duration: 0.14), value: isCollapsed)
                .frame(width: BrowserChromeLayout.sidebarRowContentSpacing + 10)

            Spacer(minLength: 0)
                .frame(width: BrowserChromeLayout.sidebarRowContentSpacing)

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
                Text(space.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.trailing, showsMenuButton ? menuButtonReservedWidth : 0)
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

    var menuButtonOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
                .fill(isMenuHovered ? BrowserChromePalette.rowCloseHover : .clear)

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: BrowserChromeLayout.sidebarCloseSymbolSize, weight: .bold))
                    .foregroundStyle(BrowserChromePalette.secondaryText)
                    .frame(
                        width: BrowserChromeLayout.sidebarCloseButtonSize,
                        height: BrowserChromeLayout.sidebarCloseButtonSize
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(BrowserSidebarCloseButtonStyle())
        }
        .frame(
            width: BrowserChromeLayout.sidebarCloseButtonSize,
            height: BrowserChromeLayout.sidebarCloseButtonSize
        )
        .contentShape(
            RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
        )
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            isMenuHovered = hovering
        }
        .opacity(showsMenuButton ? 1 : 0)
        .allowsHitTesting(showsMenuButton)
        .frame(
            width: menuButtonReservedWidth,
            height: BrowserChromeLayout.sidebarCloseButtonSize,
            alignment: .trailing
        )
    }

    var menuItems: some View {
        BrowserSpaceContextMenuContent(
            space: space,
            canDelete: canDelete,
            onBeginRename: beginRename,
            onChangeIcon: onChangeIcon,
            onDelete: onDelete
        )
    }

    var backgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
            .fill(isRowHovered ? BrowserChromePalette.rowHover : Color.clear)
    }

    // MARK: Private

    private func performPrimaryAction() {
        if hasPinnedTabs {
            onToggleCollapsed()
        } else {
            beginRename()
        }
    }

    private func beginRename() {
        draftTitle = space.title
        onBeginRename()
    }

    private func commitRename() {
        onCommitRename(draftTitle)
    }

    private func cancelRename() {
        draftTitle = space.title
        onCancelRename()
    }

    private func resetTransientInteractionState() {
        isRowHovered = false
        isMenuHovered = false
        isRowPressed = false
    }

    private func syncDraftTitleIfNeeded(isRenaming: Bool) {
        guard isRenaming else {
            return
        }

        draftTitle = space.title
    }
}

// MARK: - BrowserSpaceContextMenuContent

struct BrowserSpaceContextMenuContent: View {
    let space: BrowserChromeModel.Space
    let canDelete: Bool
    let onBeginRename: () -> Void
    let onChangeIcon: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(BrowserStrings.spaceRenameAction, action: onBeginRename)
        Menu(BrowserStrings.spaceChangeIconAction) {
            ForEach(BrowserSpaceIconCatalog.systemImageNames, id: \.self) { systemImageName in
                Button {
                    onChangeIcon(systemImageName)
                } label: {
                    Label(
                        systemImageName,
                        systemImage: space.systemImageName == systemImageName ? "checkmark" : systemImageName
                    )
                }
            }
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Text(BrowserStrings.spaceDeleteAction)
        }
        .disabled(!canDelete)
    }
}

// MARK: - BrowserSidebarSpacesBar

struct BrowserSidebarSpacesBar: View {
    let spaces: [BrowserChromeModel.Space]
    let selectedSpaceID: String?
    @ObservedObject var downloadsModel: BrowserDownloadsModel
    let isSidebarResizing: Bool
    let onSelectSpace: (String) -> Void
    let onCreateSpace: () -> Void
    let onBeginRenameSpace: (String) -> Void
    let onChangeSpaceIcon: (String, String) -> Void
    let onDeleteSpace: (String) -> Void

    @State var isDownloadsPopoverPresented = false

    var sideReserveWidth: CGFloat {
        BrowserChromeLayout.chromeButtonSize + BrowserChromeLayout.chromeButtonSpacing
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                BrowserWindowDragRegion(isEnabled: !isSidebarResizing)
                    .frame(width: sideReserveWidth)

                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                                BrowserSidebarSpaceBarButton(
                                    space: space,
                                    shortcut: BrowserSpaceShortcuts.shortcut(forSpaceIndex: index),
                                    isSelected: selectedSpaceID == space.id,
                                    canDelete: spaces.count > 1,
                                    onSelect: {
                                        onSelectSpace(space.id)
                                    },
                                    onBeginRename: {
                                        onBeginRenameSpace(space.id)
                                    },
                                    onChangeIcon: { systemImageName in
                                        onChangeSpaceIcon(systemImageName, space.id)
                                    },
                                    onDelete: {
                                        onDeleteSpace(space.id)
                                    }
                                )
                            }
                        }
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: BrowserChromeLayout.chromeButtonSize,
                            alignment: .center
                        )
                        .background {
                            BrowserWindowDragRegion(isEnabled: !isSidebarResizing)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .frame(height: BrowserChromeLayout.chromeButtonSize)

                BrowserWindowDragRegion(isEnabled: !isSidebarResizing)
                    .frame(width: sideReserveWidth)
            }

            HStack(spacing: 0) {
                BrowserDownloadsButton(
                    downloadsModel: downloadsModel,
                    isPresented: $isDownloadsPopoverPresented
                )
                .popover(isPresented: $isDownloadsPopoverPresented, arrowEdge: .bottom) {
                    BrowserDownloadsPopover(downloadsModel: downloadsModel)
                }

                Spacer(minLength: 0)

                BrowserSidebarCreateSpaceButton(
                    onCreate: onCreateSpace
                )
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: BrowserChromeLayout.chromeButtonSize)
        .allowsHitTesting(!isSidebarResizing)
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            if isSidebarResizing {
                isDownloadsPopoverPresented = false
            }
        }
    }
}

// MARK: - BrowserSidebarSpaceBarButton

struct BrowserSidebarSpaceBarButton: View {
    let space: BrowserChromeModel.Space
    let shortcut: BrowserKeyboardShortcut?
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onChangeIcon: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        BrowserChromeControlButton(
            systemImageName: space.systemImageName,
            tooltipTitle: space.title,
            tooltipShortcut: shortcut,
            tooltipPlacement: .aboveCapsule,
            isSelected: isSelected,
            pressEffect: .compress,
            action: onSelect
        )
        .contextMenu {
            BrowserSpaceContextMenuContent(
                space: space,
                canDelete: canDelete,
                onBeginRename: onBeginRename,
                onChangeIcon: onChangeIcon,
                onDelete: onDelete
            )
        }
    }
}

// MARK: - BrowserSidebarCreateSpaceButton

struct BrowserSidebarCreateSpaceButton: View {
    let onCreate: () -> Void

    var body: some View {
        BrowserChromeControlButton(
            systemImageName: "plus",
            tooltipTitle: BrowserStrings.spaceNewAction,
            tooltipShortcut: nil,
            tooltipPlacement: .aboveCapsule,
            pressEffect: .compress,
            action: onCreate
        )
    }
}
