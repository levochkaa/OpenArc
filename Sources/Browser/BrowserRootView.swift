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
    static let resizeHandle = Color.white.opacity(0.16)
    static let resizeHandleHover = Color.white.opacity(0.28)
}

private enum BrowserChromeLayout {
    static let sidebarAnimationDuration = 0.18
    static let contentInset: CGFloat = 10
    static let expandedContentCornerRadius: CGFloat = 12
    static let collapsedContentCornerRadius: CGFloat = 0
    static let sidebarOuterPadding: CGFloat = 8
    static let sidebarListSpacing: CGFloat = 5
    static let sidebarResizeHitWidth: CGFloat = sidebarOuterPadding
    static let sidebarSnapThreshold: CGFloat = 10
}

struct BrowserRootView: View {
    @ObservedObject var model: BrowserChromeModel

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                BrowserSidebarContainerView(model: model)
                    .frame(width: model.isSidebarVisible ? model.sidebarWidth : 0)
                    .clipped()
                    .allowsHitTesting(model.isSidebarVisible)

                BrowserContentView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if model.isSidebarVisible {
                BrowserSidebarResizeHandle(model: model)
                    .frame(width: BrowserChromeLayout.sidebarResizeHitWidth)
                    .offset(x: model.sidebarWidth - BrowserChromeLayout.sidebarResizeHitWidth)
                    .zIndex(1)
            }
        }
        .background(BrowserChromePalette.shellBackground)
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)
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
        ZStack {
            Color.clear

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
        VStack(spacing: 10) {
            Button(action: model.createNewTab) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Новый таб")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(BrowserChromePalette.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    isNewTabButtonHovered
                        ? BrowserChromePalette.buttonHoverBackground
                        : BrowserChromePalette.buttonBackground
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(
                            isNewTabButtonHovered
                                ? BrowserChromePalette.buttonHoverBorder
                                : BrowserChromePalette.buttonBorder,
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 11))
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

private struct BrowserSidebarRow: View {
    let tab: BrowserChromeModel.Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: 8) {
            BrowserFaviconView(url: tab.faviconURL)

            Text(tab.displayTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 0)

            if isHovered || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(BrowserChromePalette.rowCloseForeground)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(isCloseHovered ? BrowserChromePalette.rowCloseHover : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .leading)
        .background(backgroundShape)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 10)
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
    @State private var appliedContentInsets: EdgeInsets

    init(model: BrowserChromeModel) {
        self.model = model
        _appliedContentInsets = State(initialValue: Self.contentInsets(for: model.isSidebarVisible))
    }

    var body: some View {
        ZStack {
            BrowserViewportHostRepresentable(
                hostView: model.hostView,
                contentCornerRadius: contentCornerRadius
            )

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
        .clipShape(RoundedRectangle(cornerRadius: contentCornerRadius))
        .padding(appliedContentInsets)
        .background(BrowserChromePalette.shellBackground)
        .onChange(of: model.isSidebarVisible) { isSidebarVisible in
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                appliedContentInsets = Self.contentInsets(for: isSidebarVisible)
            }
        }
    }

    private var contentCornerRadius: CGFloat {
        model.isSidebarVisible
            ? BrowserChromeLayout.expandedContentCornerRadius
            : BrowserChromeLayout.collapsedContentCornerRadius
    }

    private static func contentInsets(for isSidebarVisible: Bool) -> EdgeInsets {
        guard isSidebarVisible else {
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        }

        let inset = BrowserChromeLayout.contentInset
        return EdgeInsets(top: inset, leading: 0, bottom: inset, trailing: inset)
    }
}

private struct BrowserViewportHostRepresentable: NSViewRepresentable {
    let hostView: BrowserTabHostView
    let contentCornerRadius: CGFloat

    func makeNSView(context _: Context) -> BrowserTabHostView {
        hostView.setContentCornerRadius(contentCornerRadius, animated: false)
        return hostView
    }

    func updateNSView(_ nsView: BrowserTabHostView, context: Context) {
        let shouldAnimate = context.transaction.animation != nil && !context.transaction.disablesAnimations
        nsView.setContentCornerRadius(contentCornerRadius, animated: shouldAnimate)
        nsView.needsLayout = true
        nsView.layoutSubtreeIfNeeded()
    }
}
