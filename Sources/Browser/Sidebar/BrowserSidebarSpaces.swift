import AppKit
import SwiftUI

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
