import AppKit
import SwiftUI

private enum BrowserChromePalette {
    static let shellBackground = Color.black
    static let sidebarBackground = Color.black
    static let contentBackground = Color.white
    static let rowHover = Color.white.opacity(0.08)
    static let rowSelected = Color.white.opacity(0.14)
    static let rowCloseHover = Color.white.opacity(0.12)
    static let rowCloseForeground = Color.white.opacity(0.82)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
    static let buttonBackground = Color.white.opacity(0.1)
    static let buttonHoverBackground = Color.white.opacity(0.16)
    static let buttonBorder = Color.white.opacity(0.12)
    static let buttonHoverBorder = Color.white.opacity(0.2)
    static let buttonDisabledForeground = Color.white.opacity(0.32)
    static let resizeHandle = Color.white.opacity(0.16)
    static let resizeHandleHover = Color.white.opacity(0.28)
}

private enum BrowserChromeLayout {
    static let sidebarAnimationDuration = 0.18
    static let leadingContentCornerRadius: CGFloat = 12
    static let sidebarOuterPadding: CGFloat = 8
    static let sidebarSectionSpacing: CGFloat = 10
    static let sidebarListSpacing: CGFloat = 5
    static let sidebarRowHeight: CGFloat = 36
    static let sidebarRowCornerRadius: CGFloat = 10
    static let sidebarRowHorizontalPadding: CGFloat = 11
    static let sidebarRowContentSpacing: CGFloat = 8
    static let sidebarNewTabSymbolSize: CGFloat = 14
    static let sidebarCloseButtonSize: CGFloat = 22
    static let sidebarCloseCornerRadius: CGFloat = 7
    static let sidebarCloseSymbolSize: CGFloat = 11
    static let sidebarResizeHitWidth: CGFloat = sidebarOuterPadding
    static let sidebarSnapThreshold: CGFloat = 10
    static let chromeButtonSize: CGFloat = 28
    static let chromeButtonCornerRadius: CGFloat = 9
    static let chromeButtonSpacing: CGFloat = 6
    static let windowControlsTrailingGap: CGFloat = 5
}

struct BrowserRootView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                BrowserContentView(model: model)
                    .frame(
                        width: max(proxy.size.width - sidebarLayoutWidth, 0),
                        height: proxy.size.height,
                        alignment: .leading
                    )
                    .offset(x: sidebarLayoutWidth)

                BrowserSidebarChromeView(model: model)
                    .frame(width: model.sidebarWidth, height: proxy.size.height, alignment: .leading)
                    .offset(x: sidebarOffset)
                    .allowsHitTesting(model.isSidebarVisible)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .background(BrowserChromePalette.shellBackground)
        .clipped()
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)
    }

    private var sidebarLayoutWidth: CGFloat {
        model.isSidebarVisible ? model.sidebarWidth : 0
    }

    private var sidebarOffset: CGFloat {
        model.isSidebarVisible ? 0 : -model.sidebarWidth
    }
}

private struct BrowserSidebarChromeView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        BrowserSidebarContainerView(model: model)
            .overlay(alignment: .trailing) {
                BrowserSidebarResizeHandle(model: model)
                    .frame(width: BrowserChromeLayout.sidebarResizeHitWidth)
            }
    }
}

private struct BrowserSidebarContainerView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        BrowserSidebarView(model: model)
            .background(BrowserChromePalette.sidebarBackground)
    }
}

private struct BrowserSidebarResizeHandle: View {
    @ObservedObject var model: BrowserChromeModel

    @State private var isResizeHovered = false
    @State private var isResizing = false
    @State private var isSnappedToDefaultWidth = false
    @State private var dragStartWidth: CGFloat?
    @State private var pushedResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .overlay {
                Rectangle()
                    .fill(isResizeHovered ? BrowserChromePalette.resizeHandleHover : BrowserChromePalette.resizeHandle)
                    .frame(width: 2)
                    .opacity(shouldShowResizeHandle ? 1 : 0)
            }
        .padding(.vertical, BrowserChromeLayout.sidebarOuterPadding)
        .contentShape(Rectangle())
        .onHover(perform: handleResizeHover)
        .gesture(resizeGesture)
        .onDisappear {
            if pushedResizeCursor {
                NSCursor.pop()
                pushedResizeCursor = false
            }
            isResizeHovered = false
            isResizing = false
            isSnappedToDefaultWidth = false
            dragStartWidth = nil
        }
    }

    private var shouldShowResizeHandle: Bool {
        isResizeHovered || isResizing
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                beginResizeIfNeeded()
                updateSidebarWidth(with: value.translation.width)
            }
            .onEnded { _ in
                finishResize()
            }
    }

    private func handleResizeHover(_ hovering: Bool) {
        isResizeHovered = hovering

        if hovering, !pushedResizeCursor {
            NSCursor.resizeLeftRight.push()
            pushedResizeCursor = true
        } else if !hovering, !isResizing, pushedResizeCursor {
            NSCursor.pop()
            pushedResizeCursor = false
        }
    }

    private func beginResizeIfNeeded() {
        if dragStartWidth == nil {
            dragStartWidth = model.sidebarWidth
        }

        isResizing = true

        if !pushedResizeCursor {
            NSCursor.resizeLeftRight.push()
            pushedResizeCursor = true
        }
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
        dragStartWidth = nil
        isResizing = false
        isSnappedToDefaultWidth = false

        if !isResizeHovered, pushedResizeCursor {
            NSCursor.pop()
            pushedResizeCursor = false
        }
    }
}

private struct BrowserSidebarView: View {
    @ObservedObject var model: BrowserChromeModel
    @State private var isNewTabButtonHovered = false

    var body: some View {
        VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            BrowserSidebarHeaderView(model: model)

            Button(action: model.createNewTab) {
                HStack(spacing: BrowserChromeLayout.sidebarRowContentSpacing) {
                    Image(systemName: "plus")
                        .font(.system(size: BrowserChromeLayout.sidebarNewTabSymbolSize, weight: .semibold))
                    Text("Новый таб")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(BrowserChromePalette.primaryText)
                .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
                .frame(height: BrowserChromeLayout.sidebarRowHeight)
                .background(
                    RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
                        .fill(isNewTabButtonHovered ? BrowserChromePalette.rowHover : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
            .onHover { hovering in
                isNewTabButtonHovered = hovering
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: BrowserChromeLayout.sidebarListSpacing) {
                    ForEach(model.tabs) { tab in
                        BrowserSidebarRow(
                            tab: tab,
                            isSelected: model.selectedTabID == tab.id,
                            onSelect: { model.selectTab(id: tab.id) },
                            onClose: { model.closeTab(id: tab.id) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.leading, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.bottom, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrowserChromePalette.sidebarBackground)
    }
}

private struct BrowserSidebarHeaderView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: BrowserChromeLayout.windowControlsTrailingGap) {
                BrowserWindowControlsView(showsInSidebar: model.isSidebarVisible)
                    .frame(height: BrowserChromeLayout.chromeButtonSize)
                    .fixedSize(horizontal: true, vertical: false)

                BrowserChromeControlButton(
                    systemImageName: "sidebar.left",
                    helpText: "Скрыть сайдбар",
                    action: model.toggleSidebar
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                BrowserChromeControlButton(
                    systemImageName: "chevron.backward",
                    helpText: "Назад",
                    isEnabled: model.canGoBack,
                    action: model.goBack
                )

                BrowserChromeControlButton(
                    systemImageName: "chevron.forward",
                    helpText: "Вперёд",
                    isEnabled: model.canGoForward,
                    action: model.goForward
                )

                BrowserChromeControlButton(
                    systemImageName: "arrow.clockwise",
                    helpText: "Перезагрузить",
                    isEnabled: model.canReload,
                    action: model.reloadCurrentTab
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: BrowserChromeLayout.chromeButtonSize)
        .background(BrowserWindowDragRegion())
    }
}

private struct BrowserWindowDragRegion: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

private struct BrowserChromeControlButton: View {
    let systemImageName: String
    let helpText: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isEnabled
                        ? BrowserChromePalette.primaryText
                        : BrowserChromePalette.buttonDisabledForeground
                )
                .frame(
                    width: BrowserChromeLayout.chromeButtonSize,
                    height: BrowserChromeLayout.chromeButtonSize
                )
                .background(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius)
                        .stroke(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(helpText)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonBackground.opacity(0.5)
        }

        return isHovered
            ? BrowserChromePalette.buttonHoverBackground
            : BrowserChromePalette.buttonBackground
    }

    private var borderColor: Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonBorder.opacity(0.6)
        }

        return isHovered
            ? BrowserChromePalette.buttonHoverBorder
            : BrowserChromePalette.buttonBorder
    }
}

private struct BrowserSidebarRow: View {
    let tab: BrowserChromeModel.Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: BrowserChromeLayout.sidebarRowContentSpacing) {
            BrowserFaviconView(url: tab.faviconURL)

            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isHovered || isSelected {
                Button(action: onClose) {
                    ZStack {
                        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
                            .fill(isCloseHovered ? BrowserChromePalette.rowCloseHover : Color.clear)

                        Image(systemName: "xmark")
                            .font(.system(size: BrowserChromeLayout.sidebarCloseSymbolSize, weight: .bold))
                            .foregroundStyle(BrowserChromePalette.rowCloseForeground)
                    }
                    .frame(
                        width: BrowserChromeLayout.sidebarCloseButtonSize,
                        height: BrowserChromeLayout.sidebarCloseButtonSize
                    )
                }
                .buttonStyle(.plain)
                .contentShape(
                    RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarCloseCornerRadius, style: .continuous)
                )
                .onHover { hovering in
                    isCloseHovered = hovering
                }
            }
        }
        .padding(.horizontal, BrowserChromeLayout.sidebarRowHorizontalPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: BrowserChromeLayout.sidebarRowHeight,
            maxHeight: BrowserChromeLayout.sidebarRowHeight,
            alignment: .leading
        )
        .background(backgroundShape)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
            .fill(
                isSelected
                    ? BrowserChromePalette.rowSelected
                    : (isHovered ? BrowserChromePalette.rowHover : Color.clear)
            )
    }
}

private struct BrowserFaviconView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 14, height: 14)
    }

    private var placeholder: some View {
        Image(systemName: "globe")
            .resizable()
            .scaledToFit()
            .foregroundStyle(BrowserChromePalette.secondaryText)
            .padding(1)
    }
}

private struct BrowserContentView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        ZStack {
            BrowserViewportHostRepresentable(hostView: model.hostView)

            if !model.isContextReady {
                Rectangle()
                    .fill(BrowserChromePalette.contentBackground)

                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                    Text("Запускаем браузер…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.58))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserChromePalette.contentBackground)
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(
                    topLeading: leadingCornerRadius,
                    bottomLeading: leadingCornerRadius,
                    bottomTrailing: 0,
                    topTrailing: 0
                ),
                style: .continuous
            )
        )
    }

    private var leadingCornerRadius: CGFloat {
        model.isSidebarVisible ? BrowserChromeLayout.leadingContentCornerRadius : 0
    }
}

private struct BrowserViewportHostRepresentable: NSViewRepresentable {
    let hostView: BrowserTabHostView

    func makeNSView(context _: Context) -> BrowserTabHostView {
        hostView.setContentCornerRadius(0, animated: false)
        return hostView
    }

    func updateNSView(_ nsView: BrowserTabHostView, context: Context) {
        let shouldAnimate = context.transaction.animation != nil && !context.transaction.disablesAnimations
        nsView.setContentCornerRadius(0, animated: shouldAnimate)
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }
}
