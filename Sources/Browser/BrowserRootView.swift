import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

private enum BrowserChromePalette {
    static let shellBackground = Color.black
    static let sidebarBackground = Color.black
    static let contentBackground = Color.white
    static let rowHover = Color.white.opacity(0.08)
    static let rowSelected = Color.white.opacity(0.14)
    static let rowCloseHover = Color.white.opacity(0.12)
    static let rowCloseForeground = Color.white.opacity(0.82)
    static let sidebarDivider = Color.white.opacity(0.12)
    static let sidebarClearButtonForeground = Color.white.opacity(0.3)
    static let sidebarDropIndicator = Color.white.opacity(0.96)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.58)
    static let buttonBackground = Color.white.opacity(0.1)
    static let buttonHoverBackground = Color.white.opacity(0.16)
    static let buttonBorder = Color.white.opacity(0.12)
    static let buttonHoverBorder = Color.white.opacity(0.2)
    static let buttonDisabledForeground = Color.white.opacity(0.32)
    static let chromeButtonHoverBackground = Color.white.opacity(0.14)
    static let chromeButtonPressedBackground = Color.white.opacity(0.2)
    static let chromeButtonHoverForeground = Color.white.opacity(0.98)
    static let chromeButtonPressedForeground = Color.white
    static let chromeButtonHighlightGlow = Color.white.opacity(0.1)
    static let resizeHandle = Color.white.opacity(0.16)
    static let resizeHandleHover = Color.white.opacity(0.28)
    static let commandBarBackdropTint = Color.black.opacity(0.34)
    static let commandBarPanelTint = Color.black.opacity(0.38)
    static let commandBarPanelBorder = Color.white.opacity(0.12)
    static let commandBarFieldTint = Color.white.opacity(0.06)
    static let commandBarFieldBorder = Color.white.opacity(0.08)
    static let commandBarPlaceholder = Color.white.opacity(0.36)
    static let commandBarCompletion = Color.white.opacity(0.5)
    static let commandBarSuggestionSelected = Color.white.opacity(0.1)
    static let tooltipBackground = Color.black.opacity(0.96)
    static let tooltipBorder = Color.white.opacity(0.22)
    static let tooltipText = Color.white.opacity(0.96)
    static let tooltipCaption = Color.white.opacity(0.56)
    static let tooltipShadow = Color.black.opacity(0.3)
    static let tooltipKeyBackground = Color.white
    static let tooltipKeyText = Color.black.opacity(0.92)
    static let tooltipKeyShadow = Color.black.opacity(0.12)
}

private enum BrowserChromeLayout {
    static let sidebarAnimationDuration = 0.18
    static let sidebarResizeHoverDelayNanoseconds: UInt64 = 500_000_000
    static let leadingContentCornerRadius: CGFloat = 12
    static let sidebarOuterPadding: CGFloat = 8
    static let sidebarTopDragRegionHeight: CGFloat = sidebarOuterPadding + chromeButtonSize
    static let sidebarSectionSpacing: CGFloat = 10
    static let sidebarListSpacing: CGFloat = 5
    static let sidebarRowHeight: CGFloat = 36
    static let sidebarRowCornerRadius: CGFloat = 10
    static let sidebarRowHorizontalPadding: CGFloat = 11
    static let sidebarTabTrailingPadding: CGFloat = 7
    static let sidebarRowContentSpacing: CGFloat = 8
    static let sidebarNewTabSymbolSize: CGFloat = 14
    static let sidebarCloseButtonSize: CGFloat = 22
    static let sidebarCloseButtonLeadingSpacing: CGFloat = 4
    static let sidebarCloseCornerRadius: CGFloat = 7
    static let sidebarCloseSymbolSize: CGFloat = 11
    static let sidebarDividerHeight: CGFloat = 24
    static let sidebarDropIndicatorThickness: CGFloat = 2
    static let sidebarEmptySectionDropZoneHeight: CGFloat = 14
    static let sidebarClearButtonHorizontalPadding: CGFloat = 8
    static let sidebarClearButtonVerticalPadding: CGFloat = 2
    static let sidebarResizeHitWidth: CGFloat = sidebarOuterPadding
    static let sidebarSnapThreshold: CGFloat = 10
    static let chromeButtonSize: CGFloat = 28
    static let chromeButtonSymbolSize: CGFloat = 13.5
    static let chromeButtonCornerRadius: CGFloat = 9
    static let chromeButtonSpacing: CGFloat = 6
    static let windowControlsTrailingGap: CGFloat = 5
    static let commandBarWidth: CGFloat = 720
    static let commandBarCornerRadius: CGFloat = 20
    static let commandBarShadowRadius: CGFloat = 40
    static let commandBarTopInsetMinimum: CGFloat = 92
    static let commandBarTopInsetMaximum: CGFloat = 184
    static let commandBarTopInsetFraction: CGFloat = 0.22
    static let commandBarOuterPadding: CGFloat = 4
    static let commandBarFieldHeight: CGFloat = 52
    static let commandBarFieldCornerRadius: CGFloat = 14
    static let commandBarRowHorizontalPadding: CGFloat = 14
    static let commandBarRowContentSpacing: CGFloat = 12
    static let commandBarRowVerticalPadding: CGFloat = 12
    static let commandBarSymbolSize: CGFloat = 14
    static let commandBarSymbolWidth: CGFloat = 18
    static let commandBarSuggestionTopPadding: CGFloat = 3
    static let commandBarSuggestionRowHeight: CGFloat = 42
    static let commandBarSuggestionSpacing: CGFloat = 4
    static let commandBarSuggestionBottomInset: CGFloat = 2
    static let tooltipCornerRadius: CGFloat = 12
    static let tooltipVerticalGap: CGFloat = 8
    static let tooltipHorizontalPadding: CGFloat = 12
    static let tooltipVerticalPadding: CGFloat = 10
    static let tooltipContentSpacing: CGFloat = 10
    static let tooltipKeySpacing: CGFloat = 6
    static let tooltipKeyHeight: CGFloat = 22
    static let tooltipKeyHorizontalPadding: CGFloat = 7
    static let tooltipBorderWidth: CGFloat = 0.5
    static let tooltipAnchorXFraction: CGFloat = 0.75
    static let tooltipAnchorYFraction: CGFloat = 0.75
}

private enum BrowserSidebarTabSection {
    case pinned
    case temporary

    var isPinned: Bool {
        switch self {
        case .pinned:
            true
        case .temporary:
            false
        }
    }
}

private struct BrowserSidebarTabDropTarget: Equatable {
    let section: BrowserSidebarTabSection
    let sectionIndex: Int
}

private struct AnimationCompletionObserverModifier<Value: VectorArithmetic>: AnimatableModifier {
    var targetValue: Value
    var completion: (Value) -> Void

    var animatableData: Value {
        didSet {
            notifyCompletionIfFinished()
        }
    }

    init(observedValue: Value, completion: @escaping (Value) -> Void) {
        targetValue = observedValue
        animatableData = observedValue
        self.completion = completion
    }

    func body(content: Content) -> some View {
        content
    }

    private func notifyCompletionIfFinished() {
        guard animatableData == targetValue else {
            return
        }

        DispatchQueue.main.async {
            completion(targetValue)
        }
    }
}

private extension View {
    func onAnimationCompleted<Value: VectorArithmetic>(
        for value: Value,
        perform completion: @escaping (Value) -> Void
    ) -> some View {
        modifier(AnimationCompletionObserverModifier(observedValue: value, completion: completion))
    }
}

struct BrowserRootView: View {
    @ObservedObject var model: BrowserChromeModel
    @State private var showsSidebarWindowControls: Bool
    @StateObject private var tooltipCoordinator = BrowserTooltipCoordinator()

    init(model: BrowserChromeModel) {
        self.model = model
        _showsSidebarWindowControls = State(initialValue: model.isSidebarVisible)
    }

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

                BrowserSidebarChromeView(
                    model: model,
                    showsWindowControlsInSidebar: showsSidebarWindowControls
                )
                .frame(width: model.sidebarWidth, height: proxy.size.height, alignment: .leading)
                .offset(x: sidebarOffset)
                .allowsHitTesting(model.isSidebarVisible)

                if model.commandBarModel.isPresented, sidebarLayoutWidth > 0 {
                    BrowserPassthroughInteractionObserver {
                        model.dismissCommandBar()
                    }
                    .frame(width: sidebarLayoutWidth, height: proxy.size.height)
                    .zIndex(9)
                }

                BrowserCommandBarOverlay(
                    model: model.commandBarModel,
                    blockedLeadingInset: sidebarLayoutWidth
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .zIndex(10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .background(BrowserChromePalette.shellBackground)
        .clipped()
        .environmentObject(tooltipCoordinator)
        .overlayPreferenceValue(BrowserTooltipPreferenceKey.self) { values in
            BrowserTooltipOverlay(entries: values)
        }
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: model.isSidebarVisible)
        .onChange(of: model.isSidebarVisible) { _, isSidebarVisible in
            if isSidebarVisible {
                showsSidebarWindowControls = true
            }
        }
        .onAnimationCompleted(for: sidebarVisibilityAnimationValue) { completedValue in
            showsSidebarWindowControls = model.isSidebarVisible || completedValue > 0
        }
    }

    private var sidebarLayoutWidth: CGFloat {
        model.isSidebarVisible ? model.sidebarWidth : 0
    }

    private var sidebarOffset: CGFloat {
        model.isSidebarVisible ? 0 : -model.sidebarWidth
    }

    private var sidebarVisibilityAnimationValue: CGFloat {
        model.isSidebarVisible ? 1 : 0
    }
}

private struct BrowserSidebarChromeView: View {
    @ObservedObject var model: BrowserChromeModel
    let showsWindowControlsInSidebar: Bool

    var body: some View {
        BrowserSidebarContainerView(
            model: model,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar
        )
        .overlay(alignment: .trailing) {
            BrowserSidebarResizeHandle(model: model)
                .frame(width: BrowserChromeLayout.sidebarResizeHitWidth)
        }
    }
}

private struct BrowserSidebarContainerView: View {
    @ObservedObject var model: BrowserChromeModel
    let showsWindowControlsInSidebar: Bool

    var body: some View {
        BrowserSidebarView(
            model: model,
            showsWindowControlsInSidebar: showsWindowControlsInSidebar
        )
        .background(BrowserChromePalette.sidebarBackground)
    }
}

private struct BrowserSidebarResizeHandle: View {
    @ObservedObject var model: BrowserChromeModel

    @State private var isHoveringResizeArea = false
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
            .task(id: resizeHoverActivationTaskID) {
                await activateResizeHoverIfNeeded()
            }
            .gesture(resizeGesture)
            .onDisappear {
                popResizeCursorIfNeeded()
                isHoveringResizeArea = false
                isResizeHovered = false
                isResizing = false
                isSnappedToDefaultWidth = false
                dragStartWidth = nil
            }
    }

    private var shouldShowResizeHandle: Bool {
        isResizeHovered || isResizing
    }

    private var resizeHoverActivationTaskID: Int {
        (isHoveringResizeArea ? 1 : 0) | (isResizing ? 2 : 0)
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
        isHoveringResizeArea = hovering

        if !hovering {
            isResizeHovered = false
            if !isResizing {
                popResizeCursorIfNeeded()
            }
        }
    }

    private func beginResizeIfNeeded() {
        if dragStartWidth == nil {
            dragStartWidth = model.sidebarWidth
        }

        isResizing = true

        pushResizeCursorIfNeeded()
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

        guard isHoveringResizeArea else {
            isResizeHovered = false
            popResizeCursorIfNeeded()
            return
        }

        if !isResizeHovered {
            popResizeCursorIfNeeded()
        }
    }

    private func activateResizeHoverIfNeeded() async {
        guard isHoveringResizeArea, !isResizing else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: BrowserChromeLayout.sidebarResizeHoverDelayNanoseconds)
        } catch {
            return
        }

        guard isHoveringResizeArea, !isResizing else {
            return
        }

        isResizeHovered = true
        pushResizeCursorIfNeeded()
    }

    private func pushResizeCursorIfNeeded() {
        guard !pushedResizeCursor else {
            return
        }

        NSCursor.resizeLeftRight.push()
        pushedResizeCursor = true
    }

    private func popResizeCursorIfNeeded() {
        guard pushedResizeCursor else {
            return
        }

        NSCursor.pop()
        pushedResizeCursor = false
    }
}

private struct BrowserSidebarView: View {
    @ObservedObject var model: BrowserChromeModel
    let showsWindowControlsInSidebar: Bool
    @State private var isNewTabButtonHovered = false
    @State private var isClearButtonHovered = false
    @State private var isSidebarHovered = false
    @State private var renamingTabID: String?
    @State private var draggedTabID: String?
    @State private var dropTarget: BrowserSidebarTabDropTarget?

    var body: some View {
        let pinnedTabs = model.pinnedTabs
        let temporaryTabs = model.temporaryTabs

        VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            BrowserSidebarHeaderView(
                model: model,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar
            )
            .zIndex(1)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: BrowserChromeLayout.sidebarListSpacing) {
                    if pinnedTabs.isEmpty {
                        emptySectionDropZone(for: .pinned)
                    }

                    ForEach(Array(pinnedTabs.enumerated()), id: \.element.id) { index, tab in
                        sidebarRow(for: tab, in: .pinned, sectionIndex: index)
                    }

                    BrowserSidebarTemporaryTabsDivider(
                        showsClearButton: isSidebarHovered && !temporaryTabs.isEmpty,
                        isClearButtonHovered: isClearButtonHovered,
                        onHoverClearButton: { isClearButtonHovered = $0 },
                        onClear: {
                            clearTabDragState()
                            dismissRenamingIfNeeded()
                            model.clearTemporaryTabs()
                        }
                    )

                    newTabButton

                    if temporaryTabs.isEmpty {
                        emptySectionDropZone(for: .temporary)
                    }

                    ForEach(Array(temporaryTabs.enumerated()), id: \.element.id) { index, tab in
                        sidebarRow(for: tab, in: .temporary, sectionIndex: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissRenamingIfNeeded()
                    }
            }
        }
        .padding(.top, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.leading, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.bottom, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
                isSidebarHovered = hovering
            }
            if !hovering {
                isClearButtonHovered = false
            }
        }
        .background(alignment: .topLeading) {
            BrowserWindowDragRegion()
                .frame(width: max(model.sidebarWidth - BrowserChromeLayout.sidebarResizeHitWidth, 0))
                .frame(height: BrowserChromeLayout.sidebarTopDragRegionHeight)
        }
        .background {
            ZStack {
                BrowserChromePalette.sidebarBackground

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissRenamingIfNeeded()
                    }
            }
        }
    }

    private func presentCommandBar() {
        dismissRenamingIfNeeded()
        model.presentCommandBar()
    }

    private var newTabButton: some View {
        Button(action: presentCommandBar) {
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
                    .fill(isNewTabButtonHovered ? BrowserChromePalette.rowHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        .onHover { hovering in
            isNewTabButtonHovered = hovering
        }
        .browserTooltip(
            title: BrowserCommands.newTab.helpTitle,
            shortcut: BrowserCommands.newTab.shortcut,
            isPresented: isNewTabButtonHovered
        )
    }

    private func sidebarRow(
        for tab: BrowserChromeModel.Tab,
        in section: BrowserSidebarTabSection,
        sectionIndex: Int
    ) -> some View {
        BrowserSidebarRow(
            tab: tab,
            isSelected: model.selectedTabID == tab.id,
            isRenaming: renamingTabID == tab.id,
            canArchiveTabsBelow: model.hasTabsBelow(id: tab.id),
            dropIndicatorEdge: dropIndicatorEdge(for: section, sectionIndex: sectionIndex),
            onSelect: {
                if renamingTabID != tab.id {
                    dismissRenamingIfNeeded()
                }
                model.selectTab(id: tab.id)
            },
            onCopyLink: {
                _ = model.copyTabLink(forTabID: tab.id)
            },
            onBeginRename: {
                beginRenamingTab(id: tab.id)
            },
            onCommitRename: { titleOverride in
                model.setUserTitleOverride(titleOverride, forTabID: tab.id)
                renamingTabID = nil
            },
            onCancelRename: {
                renamingTabID = nil
            },
            onClose: {
                if let renamingTabID, renamingTabID != tab.id {
                    dismissRenamingIfNeeded()
                }
                if renamingTabID == tab.id {
                    renamingTabID = nil
                }
                model.closeTab(id: tab.id)
            },
            onArchiveTabsBelow: {
                renamingTabID = nil
                model.closeTabsBelow(id: tab.id)
            }
        )
        .onDrag {
            beginTabDrag(for: tab.id)
        }
        .onDrop(
            of: [.plainText],
            delegate: BrowserSidebarTabRowDropDelegate(
                section: section,
                sectionIndex: sectionIndex,
                rowHeight: BrowserChromeLayout.sidebarRowHeight,
                draggedTabID: $draggedTabID,
                dropTarget: $dropTarget,
                canMoveToTarget: canMoveDraggedTab(to:),
                moveDraggedTab: moveDraggedTab(to:),
                clearDragState: clearTabDragState
            )
        )
    }

    private func emptySectionDropZone(for section: BrowserSidebarTabSection) -> some View {
        BrowserSidebarEmptySectionDropZone(
            showsDropIndicator: dropTarget == BrowserSidebarTabDropTarget(section: section, sectionIndex: 0)
        )
        .onDrop(
            of: [.plainText],
            delegate: BrowserSidebarEmptySectionDropDelegate(
                section: section,
                draggedTabID: $draggedTabID,
                dropTarget: $dropTarget,
                canMoveToTarget: canMoveDraggedTab(to:),
                moveDraggedTab: moveDraggedTab(to:),
                clearDragState: clearTabDragState
            )
        )
    }

    private func dismissRenamingIfNeeded() {
        guard let activeRenamingTabID = renamingTabID else {
            return
        }

        NSApp.keyWindow?.makeFirstResponder(nil)

        DispatchQueue.main.async {
            guard renamingTabID == activeRenamingTabID else {
                return
            }

            renamingTabID = nil
        }
    }

    private func beginRenamingTab(id tabID: String) {
        if let renamingTabID, renamingTabID != tabID {
            dismissRenamingIfNeeded()
        }

        DispatchQueue.main.async {
            renamingTabID = tabID
        }
    }

    private func beginTabDrag(for tabID: String) -> NSItemProvider {
        dismissRenamingIfNeeded()
        draggedTabID = tabID
        dropTarget = nil
        return NSItemProvider(object: tabID as NSString)
    }

    private func dropIndicatorEdge(
        for section: BrowserSidebarTabSection,
        sectionIndex: Int
    ) -> VerticalEdge? {
        guard dropTarget?.section == section else {
            return nil
        }

        if dropTarget?.sectionIndex == sectionIndex {
            return .top
        }

        if dropTarget?.sectionIndex == sectionIndex + 1 {
            return .bottom
        }

        return nil
    }

    private func canMoveDraggedTab(to target: BrowserSidebarTabDropTarget) -> Bool {
        guard let draggedTabID else {
            return false
        }

        return model.canMoveTab(
            withID: draggedTabID,
            toPinnedState: target.section.isPinned,
            atSectionIndex: target.sectionIndex
        )
    }

    private func moveDraggedTab(to target: BrowserSidebarTabDropTarget) {
        guard let draggedTabID else {
            return
        }

        dismissRenamingIfNeeded()
        model.moveTab(
            withID: draggedTabID,
            toPinnedState: target.section.isPinned,
            atSectionIndex: target.sectionIndex
        )
        clearTabDragState()
    }

    private func clearTabDragState() {
        draggedTabID = nil
        dropTarget = nil
    }
}

private struct BrowserSidebarTabRowDropDelegate: DropDelegate {
    let section: BrowserSidebarTabSection
    let sectionIndex: Int
    let rowHeight: CGFloat
    @Binding var draggedTabID: String?
    @Binding var dropTarget: BrowserSidebarTabDropTarget?
    let canMoveToTarget: (BrowserSidebarTabDropTarget) -> Bool
    let moveDraggedTab: (BrowserSidebarTabDropTarget) -> Void
    let clearDragState: () -> Void

    func validateDrop(_ info: DropInfo) -> Bool {
        draggedTabID != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(_ info: DropInfo) {
        updateDropTarget(with: info)
    }

    func dropUpdated(_ info: DropInfo) -> DropProposal? {
        updateDropTarget(with: info)
        return DropProposal(operation: .move)
    }

    func dropExited(_: DropInfo) {
        if
            let dropTarget,
            dropTarget.section == section,
            dropTarget.sectionIndex == sectionIndex || dropTarget.sectionIndex == sectionIndex + 1
        {
            self.dropTarget = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = makeDropTarget(from: info)
        guard canMoveToTarget(target) else {
            clearDragState()
            return false
        }

        moveDraggedTab(target)
        return true
    }

    private func updateDropTarget(with info: DropInfo) {
        let target = makeDropTarget(from: info)
        dropTarget = canMoveToTarget(target) ? target : nil
    }

    private func makeDropTarget(from info: DropInfo) -> BrowserSidebarTabDropTarget {
        let isUpperHalf = info.location.y < rowHeight / 2
        return BrowserSidebarTabDropTarget(
            section: section,
            sectionIndex: sectionIndex + (isUpperHalf ? 0 : 1)
        )
    }
}

private struct BrowserSidebarEmptySectionDropDelegate: DropDelegate {
    let section: BrowserSidebarTabSection
    @Binding var draggedTabID: String?
    @Binding var dropTarget: BrowserSidebarTabDropTarget?
    let canMoveToTarget: (BrowserSidebarTabDropTarget) -> Bool
    let moveDraggedTab: (BrowserSidebarTabDropTarget) -> Void
    let clearDragState: () -> Void

    func validateDrop(_ info: DropInfo) -> Bool {
        draggedTabID != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(_: DropInfo) {
        updateDropTarget()
    }

    func dropUpdated(_: DropInfo) -> DropProposal? {
        updateDropTarget()
        return DropProposal(operation: .move)
    }

    func dropExited(_: DropInfo) {
        if dropTarget == BrowserSidebarTabDropTarget(section: section, sectionIndex: 0) {
            dropTarget = nil
        }
    }

    func performDrop(info _: DropInfo) -> Bool {
        let target = BrowserSidebarTabDropTarget(section: section, sectionIndex: 0)
        guard canMoveToTarget(target) else {
            clearDragState()
            return false
        }

        moveDraggedTab(target)
        return true
    }

    private func updateDropTarget() {
        let target = BrowserSidebarTabDropTarget(section: section, sectionIndex: 0)
        dropTarget = canMoveToTarget(target) ? target : nil
    }
}

private struct BrowserSidebarEmptySectionDropZone: View {
    let showsDropIndicator: Bool

    var body: some View {
        Color.clear
            .frame(height: BrowserChromeLayout.sidebarEmptySectionDropZoneHeight)
            .overlay(alignment: .center) {
                if showsDropIndicator {
                    BrowserSidebarDropIndicator()
                }
            }
            .contentShape(Rectangle())
    }
}

private struct BrowserSidebarTemporaryTabsDivider: View {
    let showsClearButton: Bool
    let isClearButtonHovered: Bool
    let onHoverClearButton: (Bool) -> Void
    let onClear: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Rectangle()
                .fill(BrowserChromePalette.sidebarDivider)
                .frame(height: 1)

            if showsClearButton {
                Button(action: onClear) {
                    Text(BrowserStrings.sidebarClearTemporaryTabs)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(
                            isClearButtonHovered
                                ? BrowserChromePalette.secondaryText
                                : BrowserChromePalette.sidebarClearButtonForeground
                        )
                        .padding(.horizontal, BrowserChromeLayout.sidebarClearButtonHorizontalPadding)
                        .padding(.vertical, BrowserChromeLayout.sidebarClearButtonVerticalPadding)
                        .background(BrowserChromePalette.sidebarBackground)
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.12), value: isClearButtonHovered)
                .transition(.opacity)
                .onHover(perform: onHoverClearButton)
                .browserTooltip(
                    title: BrowserCommands.clearTemporaryTabs.helpTitle,
                    shortcut: BrowserCommands.clearTemporaryTabs.shortcut,
                    isPresented: isClearButtonHovered
                )
            }
        }
        .frame(height: BrowserChromeLayout.sidebarDividerHeight)
        .animation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration), value: showsClearButton)
    }
}

private struct BrowserPassthroughInteractionObserver: NSViewRepresentable {
    let onInteraction: () -> Void

    func makeNSView(context _: Context) -> BrowserPassthroughInteractionNSView {
        let view = BrowserPassthroughInteractionNSView()
        view.onInteraction = onInteraction
        return view
    }

    func updateNSView(_ nsView: BrowserPassthroughInteractionNSView, context _: Context) {
        nsView.onInteraction = onInteraction
    }
}

private final class BrowserPassthroughInteractionNSView: NSView {
    var onInteraction: () -> Void = {}

    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeLocalMonitor()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            removeLocalMonitor()
        } else {
            installLocalMonitorIfNeeded()
        }
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            guard let window, event.window === window else {
                return event
            }

            let frameInWindow = convert(bounds, to: nil)
            if frameInWindow.contains(event.locationInWindow) {
                onInteraction()
            }

            return event
        }
    }

    private func removeLocalMonitor() {
        guard let localMonitor else {
            return
        }

        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }
}

private struct BrowserCommandBarOverlay: View {
    @ObservedObject var model: BrowserCommandBarModel
    let blockedLeadingInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if model.isPresented {
                    HStack(spacing: 0) {
                        Color.clear
                            .frame(width: blockedLeadingInset)
                            .allowsHitTesting(false)

                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.dismiss()
                            }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .ignoresSafeArea()

                    VStack(spacing: 0) {
                        inputField

                        if !model.suggestions.isEmpty {
                            Rectangle()
                                .fill(BrowserChromePalette.commandBarPanelBorder)
                                .frame(height: 1)
                                .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)

                            BrowserCommandSuggestionList(model: model)
                                .padding(.horizontal, BrowserChromeLayout.commandBarOuterPadding)
                                .padding(.bottom, BrowserChromeLayout.commandBarOuterPadding)
                                .padding(.top, BrowserChromeLayout.commandBarSuggestionTopPadding)
                        }
                    }
                    .padding(BrowserChromeLayout.commandBarOuterPadding)
                    .frame(width: BrowserChromeLayout.commandBarWidth, alignment: .top)
                    .background(panelBackground)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.commandBarCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay(panelBorder)
                    .shadow(color: Color.black.opacity(0.38), radius: BrowserChromeLayout.commandBarShadowRadius, y: 18)
                    .padding(.top, commandBarTopInset(for: proxy.size.height))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(model.isPresented)
    }

    private var inputField: some View {
        HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
            Image(systemName: leadingSymbolName)
                .font(.system(size: BrowserChromeLayout.commandBarSymbolSize, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.primaryText)
                .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(BrowserStrings.commandBarPlaceholder)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.commandBarPlaceholder)
                        .allowsHitTesting(false)
                }

                BrowserCommandQueryTextField(
                    text: Binding(
                        get: { model.query },
                        set: { model.query = $0 }
                    ),
                    previewDisplayText: model.previewDisplayText,
                    inlineCompletionSuffix: model.inlineCompletionSuffix,
                    isFocused: model.isPresented,
                    onMoveUp: { model.moveSelection(by: -1) },
                    onMoveDown: { model.moveSelection(by: 1) },
                    onAcceptCompletion: { _ = model.acceptSelectedSuggestion() },
                    onSubmit: { model.submitSelection() },
                    onDismiss: { model.dismiss() }
                )
            }
        }
        .padding(
            .horizontal,
            BrowserChromeLayout.commandBarRowHorizontalPadding + BrowserChromeLayout.commandBarOuterPadding
        )
        .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
        .frame(minHeight: BrowserChromeLayout.commandBarFieldHeight)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.commandBarCornerRadius, style: .continuous)
            .fill(BrowserChromePalette.commandBarPanelTint)
            .background(
                BrowserVisualEffectView(material: .hudWindow)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: BrowserChromeLayout.commandBarCornerRadius,
                            style: .continuous
                        )
                    )
            )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.commandBarCornerRadius, style: .continuous)
            .stroke(BrowserChromePalette.commandBarPanelBorder, lineWidth: 1)
    }

    private var leadingSymbolName: String {
        model.selectedSuggestion?.systemImageName ?? "magnifyingglass"
    }

    private func commandBarTopInset(for availableHeight: CGFloat) -> CGFloat {
        min(
            max(
                availableHeight * BrowserChromeLayout.commandBarTopInsetFraction,
                BrowserChromeLayout.commandBarTopInsetMinimum
            ),
            BrowserChromeLayout.commandBarTopInsetMaximum
        )
    }
}

private struct BrowserCommandSuggestionList: View {
    @ObservedObject var model: BrowserCommandBarModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: BrowserChromeLayout.commandBarSuggestionSpacing) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { _, suggestion in
                        BrowserCommandSuggestionRow(
                            suggestion: suggestion,
                            isSelected: model.selectedSuggestionID == suggestion.id,
                            onPress: { model.submitSuggestion(id: suggestion.id) }
                        )
                        .id(suggestion.id)
                    }
                }
                .padding(.bottom, BrowserChromeLayout.commandBarSuggestionBottomInset)
            }
            .frame(height: visibleHeight)
            .onChange(of: model.selectedSuggestionID) { _, selectedSuggestionID in
                guard let selectedSuggestionID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selectedSuggestionID, anchor: .center)
                }
            }
        }
    }

    private var visibleSuggestionCount: Int {
        min(model.suggestions.count, BrowserCommandBarModel.maximumVisibleSuggestions)
    }

    private var visibleHeight: CGFloat {
        guard visibleSuggestionCount > 0 else {
            return 0
        }

        return CGFloat(visibleSuggestionCount) * BrowserChromeLayout.commandBarSuggestionRowHeight
            + CGFloat(max(visibleSuggestionCount - 1, 0)) * BrowserChromeLayout.commandBarSuggestionSpacing
            + BrowserChromeLayout.commandBarSuggestionBottomInset
    }
}

private struct BrowserCommandSuggestionRow: View {
    let suggestion: BrowserCommandSuggestion
    let isSelected: Bool
    let onPress: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onPress) {
            HStack(spacing: BrowserChromeLayout.commandBarRowContentSpacing) {
                Image(systemName: suggestion.systemImageName)
                    .font(.system(size: BrowserChromeLayout.commandBarSymbolSize, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .frame(width: BrowserChromeLayout.commandBarSymbolWidth)

                Text(suggestion.displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrowserChromeLayout.commandBarRowHorizontalPadding)
            .padding(.vertical, BrowserChromeLayout.commandBarRowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: BrowserChromeLayout.commandBarSuggestionRowHeight)
            .background(backgroundShape)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((isSelected || isHovered) ? BrowserChromePalette.commandBarSuggestionSelected : Color.clear)
    }
}

private struct BrowserCommandQueryTextField: NSViewRepresentable {
    @Binding var text: String
    let previewDisplayText: String?
    let inlineCompletionSuffix: String?
    let isFocused: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onAcceptCompletion: () -> Void
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onAcceptCompletion: onAcceptCompletion,
            onSubmit: onSubmit,
            onDismiss: onDismiss
        )
    }

    func makeNSView(context: Context) -> BrowserCommandNSTextField {
        let textField = BrowserCommandNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: BrowserCommandNSTextField, context: Context) {
        context.coordinator.update(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onAcceptCompletion: onAcceptCompletion,
            onSubmit: onSubmit,
            onDismiss: onDismiss
        )

        nsView.syncCommandPresentation(
            text: text,
            previewDisplayText: previewDisplayText,
            inlineCompletionSuffix: inlineCompletionSuffix,
            shouldFocus: isFocused
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onMoveUp: () -> Void
        private var onMoveDown: () -> Void
        private var onAcceptCompletion: () -> Void
        private var onSubmit: () -> Void
        private var onDismiss: () -> Void

        init(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onAcceptCompletion: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onAcceptCompletion = onAcceptCompletion
            self.onSubmit = onSubmit
            self.onDismiss = onDismiss
        }

        func update(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onAcceptCompletion: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onAcceptCompletion = onAcceptCompletion
            self.onSubmit = onSubmit
            self.onDismiss = onDismiss
        }

        func controlTextDidChange(_ notification: Notification) {
            guard
                let textField = notification.object as? BrowserCommandNSTextField,
                !textField.isApplyingPresentation
            else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                onMoveUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                onMoveDown()
                return true
            case #selector(NSResponder.moveRight(_:)):
                guard
                    let textField = control as? BrowserCommandNSTextField,
                    textField.hasSuggestionPreview
                else {
                    return false
                }

                onAcceptCompletion()
                return true
            case #selector(NSResponder.selectAll(_:)):
                textView.selectAll(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onDismiss()
                return true
            default:
                return false
            }
        }
    }
}

private final class BrowserCommandNSTextField: NSTextField {
    fileprivate private(set) var isApplyingPresentation = false

    private var pendingFocus = false
    private var committedText = ""
    private var previewDisplayText: String?
    private var inlineCompletionSuffix: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: 22, weight: .medium)
        textColor = NSColor.white.withAlphaComponent(0.92)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    var hasSuggestionPreview: Bool {
        guard previewDisplayText != nil else {
            return false
        }

        if let editor = currentEditor() as? NSTextView {
            return editor.string == desiredDisplayText
        }

        return stringValue == desiredDisplayText
    }

    func syncCommandPresentation(
        text: String,
        previewDisplayText: String?,
        inlineCompletionSuffix: String?,
        shouldFocus: Bool
    ) {
        committedText = text
        self.previewDisplayText = previewDisplayText
        self.inlineCompletionSuffix = inlineCompletionSuffix
        pendingFocus = shouldFocus
        syncDisplayedText()
        syncFocus(shouldFocus)
    }

    private func syncFocus(_ shouldFocus: Bool) {
        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard !isEditing else {
                syncDisplayedText()
                applyEditorAppearance()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else {
                    return
                }

                _ = self.window?.makeFirstResponder(self)
                syncDisplayedText()
                applyEditorAppearance()
            }
            return
        }

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private var desiredDisplayText: String {
        previewDisplayText ?? committedText
    }

    private var previewSelectionRange: NSRange? {
        guard let previewDisplayText, previewDisplayText != committedText else {
            return nil
        }

        if let inlineCompletionSuffix, !inlineCompletionSuffix.isEmpty {
            return NSRange(
                location: (committedText as NSString).length,
                length: (inlineCompletionSuffix as NSString).length
            )
        }

        return nil
    }

    private func syncDisplayedText() {
        let targetDisplayText = desiredDisplayText
        let targetSelectionRange = previewSelectionRange

        if let editor = currentEditor() as? NSTextView {
            let needsStringUpdate = editor.string != targetDisplayText || stringValue != targetDisplayText
            let needsPreviewSelection = targetSelectionRange != nil && editor.selectedRange() != targetSelectionRange
            let needsSelectionCollapse =
                targetSelectionRange == nil &&
                editor.string == targetDisplayText &&
                editor.selectedRange().length > 0

            guard needsStringUpdate || needsPreviewSelection || needsSelectionCollapse else {
                applyEditorAppearance()
                return
            }

            isApplyingPresentation = true
            stringValue = targetDisplayText
            editor.string = targetDisplayText

            if let targetSelectionRange {
                editor.setSelectedRange(targetSelectionRange)
            } else if needsStringUpdate || needsSelectionCollapse {
                editor.setSelectedRange(
                    NSRange(location: (targetDisplayText as NSString).length, length: 0)
                )
            }

            isApplyingPresentation = false
            applyEditorAppearance()
            return
        }

        guard stringValue != targetDisplayText else {
            return
        }

        isApplyingPresentation = true
        stringValue = targetDisplayText
        isApplyingPresentation = false
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = .white
        editor.textColor = .white.withAlphaComponent(0.92)
        editor.drawsBackground = false
    }
}

private struct BrowserSidebarTitleTextField: NSViewRepresentable {
    @Binding var text: String
    let isFocused: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onBlur: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel, onBlur: onBlur)
    }

    func makeNSView(context: Context) -> BrowserSidebarRenameNSTextField {
        let textField = BrowserSidebarRenameNSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        return textField
    }

    func updateNSView(_ nsView: BrowserSidebarRenameNSTextField, context: Context) {
        context.coordinator.update(text: $text, onSubmit: onSubmit, onCancel: onCancel, onBlur: onBlur)

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        nsView.syncFocus(isFocused)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private var onSubmit: () -> Void
        private var onCancel: () -> Void
        private var onBlur: () -> Void
        private var suppressesNextBlur = false

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onBlur: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onBlur = onBlur
        }

        func update(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onBlur: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.onBlur = onBlur
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }

            if text.wrappedValue != textField.stringValue {
                text.wrappedValue = textField.stringValue
            }
        }

        func controlTextDidEndEditing(_: Notification) {
            if suppressesNextBlur {
                suppressesNextBlur = false
                return
            }

            onBlur()
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                suppressesNextBlur = true
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressesNextBlur = true
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private final class BrowserSidebarRenameNSTextField: NSTextField {
    private var pendingFocus = false
    private var pendingSelectAll = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = .systemFont(ofSize: 12.5, weight: .medium)
        textColor = .white.withAlphaComponent(0.92)
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 17)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        applyEditorAppearance()
        selectAllTextIfNeeded()
        return didBecomeFirstResponder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if pendingFocus {
            syncFocus(true)
        }
    }

    func syncFocus(_ shouldFocus: Bool) {
        if shouldFocus, !pendingFocus {
            pendingSelectAll = true
        }

        pendingFocus = shouldFocus

        guard let window else {
            return
        }

        let currentEditor = currentEditor()
        let isEditing = window.firstResponder === currentEditor || window.firstResponder === self

        if shouldFocus {
            guard !isEditing else {
                applyEditorAppearance()
                selectAllTextIfNeeded()
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, pendingFocus else {
                    return
                }

                _ = self.window?.makeFirstResponder(self)
                applyEditorAppearance()
                selectAllTextIfNeeded()
            }
            return
        }

        pendingSelectAll = false

        if isEditing {
            window.makeFirstResponder(nil)
        }
    }

    private func selectAllTextIfNeeded() {
        guard pendingSelectAll else {
            return
        }

        if let editor = currentEditor() as? NSTextView {
            editor.selectAll(nil)
            pendingSelectAll = false
            return
        }

        if window?.firstResponder === self {
            selectText(nil)
            pendingSelectAll = false
        }
    }

    private func applyEditorAppearance() {
        guard let editor = currentEditor() as? NSTextView else {
            return
        }

        editor.insertionPointColor = .white
        editor.textColor = .white.withAlphaComponent(0.92)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12.5, weight: .medium)
        editor.textContainerInset = NSSize(width: 0, height: 0.5)
    }
}

private struct BrowserVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}

private struct BrowserSidebarHeaderView: View {
    @ObservedObject var model: BrowserChromeModel
    let showsWindowControlsInSidebar: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: BrowserChromeLayout.windowControlsTrailingGap) {
                BrowserWindowControlsView(showsInSidebar: showsWindowControlsInSidebar)
                    .frame(height: BrowserChromeLayout.chromeButtonSize)
                    .fixedSize(horizontal: true, vertical: false)

                BrowserChromeControlButton(
                    systemImageName: "sidebar.left",
                    tooltipTitle: BrowserCommands.toggleSidebar.helpTitle,
                    tooltipShortcut: BrowserCommands.toggleSidebar.shortcut,
                    pressEffect: .compress,
                    action: model.toggleSidebar
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: BrowserChromeLayout.chromeButtonSpacing) {
                BrowserChromeControlButton(
                    systemImageName: "arrow.backward",
                    tooltipTitle: BrowserCommands.goBack.helpTitle,
                    tooltipShortcut: BrowserCommands.goBack.shortcut,
                    isEnabled: model.canGoBack,
                    pressEffect: .moveLeft,
                    action: model.goBack
                )

                BrowserChromeControlButton(
                    systemImageName: "arrow.forward",
                    tooltipTitle: BrowserCommands.goForward.helpTitle,
                    tooltipShortcut: BrowserCommands.goForward.shortcut,
                    isEnabled: model.canGoForward,
                    pressEffect: .moveRight,
                    action: model.goForward
                )

                if model.canStopLoading {
                    BrowserChromeControlButton(
                        systemImageName: "xmark",
                        tooltipTitle: BrowserStrings.navigationStopLoading,
                        tooltipShortcut: nil,
                        isEnabled: model.canStopLoading,
                        pressEffect: .compress,
                        action: model.stopLoadingCurrentTab
                    )
                } else {
                    BrowserChromeControlButton(
                        systemImageName: "arrow.clockwise",
                        tooltipTitle: BrowserCommands.reload.helpTitle,
                        tooltipShortcut: BrowserCommands.reload.shortcut,
                        isEnabled: model.canReload,
                        pressEffect: .rotateClockwise,
                        action: model.reloadCurrentTab
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: BrowserChromeLayout.chromeButtonSize)
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
    let tooltipTitle: String
    let tooltipShortcut: BrowserKeyboardShortcut?
    var isEnabled = true
    var pressEffect: BrowserChromeControlPressEffect = .none
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: BrowserChromeLayout.chromeButtonSymbolSize, weight: .semibold))
        }
        .buttonStyle(
            BrowserChromeControlButtonStyle(
                isEnabled: isEnabled,
                isHovered: isHovered,
                pressEffect: pressEffect
            )
        )
        .disabled(!isEnabled)
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius))
        .onHover { hovering in
            isHovered = hovering
        }
        .browserTooltip(
            title: tooltipTitle,
            shortcut: tooltipShortcut,
            isPresented: isHovered
        )
    }
}

private struct BrowserShortcutTooltipModifier: ViewModifier {
    @EnvironmentObject private var tooltipCoordinator: BrowserTooltipCoordinator

    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let isPresented: Bool

    @State private var tooltipID = UUID()

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: BrowserTooltipPreferenceKey.self, value: .bounds) { bounds in
                guard tooltipCoordinator.activeTooltipID == tooltipID else {
                    return []
                }

                return [
                    BrowserTooltipPreferenceEntry(
                        id: tooltipID,
                        bounds: bounds,
                        title: title,
                        caption: caption,
                        shortcut: shortcut
                    ),
                ]
            }
            .onAppear {
                if isPresented {
                    tooltipCoordinator.setHovering(true, for: tooltipID)
                }
            }
            .onChange(of: isPresented) { _, isPresented in
                tooltipCoordinator.setHovering(isPresented, for: tooltipID)
            }
            .onDisappear {
                tooltipCoordinator.setHovering(false, for: tooltipID)
            }
    }
}

private extension View {
    func browserTooltip(
        title: String,
        caption: String? = nil,
        shortcut: BrowserKeyboardShortcut?,
        isPresented: Bool
    ) -> some View {
        modifier(
            BrowserShortcutTooltipModifier(
                title: title,
                caption: caption,
                shortcut: shortcut,
                isPresented: isPresented
            )
        )
    }
}

private struct BrowserTooltipPreferenceEntry {
    let id: UUID
    let bounds: Anchor<CGRect>
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
}

private struct BrowserTooltipPreferenceKey: PreferenceKey {
    static var defaultValue: [BrowserTooltipPreferenceEntry] = []

    static func reduce(value: inout [BrowserTooltipPreferenceEntry], nextValue: () -> [BrowserTooltipPreferenceEntry]) {
        value.append(contentsOf: nextValue())
    }
}

private struct BrowserTooltipOverlay: View {
    let entries: [BrowserTooltipPreferenceEntry]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.id) { entry in
                    let sourceFrame = proxy[entry.bounds]

                    BrowserShortcutTooltip(
                        title: entry.title,
                        caption: entry.caption,
                        shortcut: entry.shortcut
                    )
                    .fixedSize()
                    .offset(
                        x: sourceFrame.minX + sourceFrame.width * BrowserChromeLayout.tooltipAnchorXFraction,
                        y: sourceFrame.minY + sourceFrame.height * BrowserChromeLayout.tooltipAnchorYFraction
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: entries.map(\.id))
    }
}

private struct BrowserShortcutTooltip: View {
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?

    var body: some View {
        HStack(spacing: BrowserChromeLayout.tooltipContentSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.tooltipText)
                    .fixedSize()

                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.tooltipCaption)
                        .fixedSize()
                }
            }

            if let shortcut {
                BrowserShortcutKeyCapsView(shortcut: shortcut)
            }
        }
        .padding(.horizontal, BrowserChromeLayout.tooltipHorizontalPadding)
        .padding(.vertical, BrowserChromeLayout.tooltipVerticalPadding)
        .background(tooltipBackground)
        .fixedSize()
        .shadow(
            color: BrowserChromePalette.tooltipShadow,
            radius: 18,
            x: 0,
            y: 10
        )
    }

    private var tooltipBackground: some View {
        tooltipShape
            .fill(BrowserChromePalette.tooltipBackground)
            .overlay(
                tooltipShape.stroke(
                    BrowserChromePalette.tooltipBorder,
                    lineWidth: BrowserChromeLayout.tooltipBorderWidth
                )
            )
    }

    private var tooltipShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: BrowserChromeLayout.tooltipCornerRadius,
                bottomTrailing: BrowserChromeLayout.tooltipCornerRadius,
                topTrailing: BrowserChromeLayout.tooltipCornerRadius
            ),
            style: .continuous
        )
    }
}

private struct BrowserShortcutKeyCapsView: View {
    let shortcut: BrowserKeyboardShortcut

    var body: some View {
        HStack(spacing: BrowserChromeLayout.tooltipKeySpacing) {
            ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { _, keyCap in
                Text(keyCap)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.tooltipKeyText)
                    .padding(.horizontal, BrowserChromeLayout.tooltipKeyHorizontalPadding)
                    .frame(minWidth: BrowserChromeLayout.tooltipKeyHeight)
                    .frame(height: BrowserChromeLayout.tooltipKeyHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(BrowserChromePalette.tooltipKeyBackground)
                    )
                    .shadow(
                        color: BrowserChromePalette.tooltipKeyShadow,
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            }
        }
    }
}

private enum BrowserChromeControlPressEffect {
    case none
    case compress
    case moveLeft
    case moveRight
    case rotateClockwise
}

private struct BrowserChromeControlButtonStyle: ButtonStyle {
    let isEnabled: Bool
    let isHovered: Bool
    let pressEffect: BrowserChromeControlPressEffect

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed
        let buttonShape = RoundedRectangle(
            cornerRadius: BrowserChromeLayout.chromeButtonCornerRadius,
            style: .continuous
        )

        return ZStack {
            buttonShape
                .fill(backgroundColor(isPressed: isPressed))

            configuration.label
                .foregroundStyle(foregroundColor(isPressed: isPressed))
                .offset(x: horizontalOffset(isPressed: isPressed))
                .rotationEffect(.degrees(rotationAngle(isPressed: isPressed)))
                .scaleEffect(scale(isPressed: isPressed))
        }
        .frame(
            width: BrowserChromeLayout.chromeButtonSize,
            height: BrowserChromeLayout.chromeButtonSize
        )
        .shadow(
            color: shadowColor(isPressed: isPressed),
            radius: shadowRadius(isPressed: isPressed)
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return .clear
        }

        if isPressed {
            return BrowserChromePalette.chromeButtonPressedBackground
        }

        if isHovered {
            return BrowserChromePalette.chromeButtonHoverBackground
        }

        return .clear
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        guard isEnabled else {
            return BrowserChromePalette.buttonDisabledForeground
        }

        if isPressed {
            return BrowserChromePalette.chromeButtonPressedForeground
        }

        return BrowserChromePalette.secondaryText
    }

    private func horizontalOffset(isPressed: Bool) -> CGFloat {
        guard isPressed else {
            return 0
        }

        switch pressEffect {
        case .moveLeft:
            return -2
        case .moveRight:
            return 2
        case .none, .compress, .rotateClockwise:
            return 0
        }
    }

    private func rotationAngle(isPressed: Bool) -> Double {
        guard isPressed else {
            return 0
        }

        switch pressEffect {
        case .rotateClockwise:
            return 90
        case .none, .compress, .moveLeft, .moveRight:
            return 0
        }
    }

    private func scale(isPressed: Bool) -> CGFloat {
        guard isPressed else {
            return 1
        }

        switch pressEffect {
        case .compress:
            return 0.9
        case .none, .moveLeft, .moveRight, .rotateClockwise:
            return 1
        }
    }

    private func shadowColor(isPressed: Bool) -> Color {
        guard isEnabled, isHovered || isPressed else {
            return .clear
        }

        return BrowserChromePalette.chromeButtonHighlightGlow
    }

    private func shadowRadius(isPressed: Bool) -> CGFloat {
        guard isEnabled, isHovered || isPressed else {
            return 0
        }

        return isPressed ? 10 : 8
    }
}

private struct BrowserSidebarCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct BrowserSidebarRow: View {
    let tab: BrowserChromeModel.Tab
    let isSelected: Bool
    let isRenaming: Bool
    let canArchiveTabsBelow: Bool
    let dropIndicatorEdge: VerticalEdge?
    let onSelect: () -> Void
    let onCopyLink: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onClose: () -> Void
    let onArchiveTabsBelow: () -> Void

    @State private var isRowHovered = false
    @State private var isCloseHovered = false
    @State private var draftTitle = ""
    @State private var hoverTrackingWidth: CGFloat = 0

    var body: some View {
        let spacing = BrowserChromeLayout.sidebarRowContentSpacing

        HStack(spacing: 0) {
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
            isPresented: isRowHovered && !isCloseHovered && !isRenaming
        )
        .padding(.leading, BrowserChromeLayout.sidebarRowHorizontalPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: BrowserChromeLayout.sidebarRowHeight,
            maxHeight: BrowserChromeLayout.sidebarRowHeight,
            alignment: .leading
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        hoverTrackingWidth = proxy.size.width
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        hoverTrackingWidth = width
                    }
            }
        }
        .overlay(alignment: .trailing) {
            if !isRenaming {
                closeButtonOverlay
                    .padding(.trailing, BrowserChromeLayout.sidebarTabTrailingPadding)
            }
        }
        .background(backgroundShape)
        .overlay(alignment: dropIndicatorAlignment) {
            if dropIndicatorEdge != nil {
                BrowserSidebarDropIndicator()
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius))
        .onTapGesture {
            guard !isRenaming else {
                return
            }

            onSelect()
        }
        .onTapGesture(count: 2) {
            beginRename()
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                guard !isRenaming else {
                    isRowHovered = true
                    isCloseHovered = false
                    return
                }

                isRowHovered = true
                isCloseHovered = hoverTrackingWidth > 0 && location.x >= closeZoneMinX
            case .ended:
                isRowHovered = false
                isCloseHovered = false
            }
        }
        .onAppear {
            syncDraftTitleIfNeeded(isRenaming: isRenaming)
        }
        .onChange(of: isRenaming) { _, isRenaming in
            syncDraftTitleIfNeeded(isRenaming: isRenaming)
        }
        .contextMenu {
            copyLinkMenuItem
            shareMenuItem
            Button(BrowserStrings.tabRenameAction, action: beginRename)
            Divider()
            Button(BrowserStrings.tabArchiveAction, role: .destructive, action: onClose)
            Button(
                BrowserStrings.tabArchiveTabsBelowAction,
                role: .destructive,
                action: onArchiveTabsBelow
            )
            .disabled(!canArchiveTabsBelow)
        }
    }

    private var closeButtonBackgroundColor: Color {
        (isCloseHovered || (isSelected && showsCloseButton)) ? BrowserChromePalette.rowCloseHover : .clear
    }

    private var closeZoneMinX: CGFloat {
        max(
            hoverTrackingWidth
                - BrowserChromeLayout.sidebarTabTrailingPadding
                - closeButtonReservedWidth,
            0
        )
    }

    private var closeButtonReservedWidth: CGFloat {
        BrowserChromeLayout.sidebarCloseButtonSize + BrowserChromeLayout.sidebarCloseButtonLeadingSpacing
    }

    private var showsCloseButton: Bool {
        isRowHovered
    }

    private var closeButtonOverlay: some View {
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
            .opacity(showsCloseButton ? 1 : 0)
            .allowsHitTesting(showsCloseButton)
        }
        .frame(
            width: closeButtonReservedWidth,
            height: BrowserChromeLayout.sidebarCloseButtonSize,
            alignment: .trailing
        )
        .browserTooltip(
            title: BrowserStrings.tabArchiveTooltip,
            shortcut: nil,
            isPresented: isCloseHovered
        )
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarRowCornerRadius)
            .fill(
                isSelected
                    ? BrowserChromePalette.rowSelected
                    : (isRowHovered ? BrowserChromePalette.rowHover : Color.clear)
            )
    }

    private var dropIndicatorAlignment: Alignment {
        switch dropIndicatorEdge {
        case .top:
            .top
        case .bottom:
            .bottom
        case nil:
            .center
        }
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

    private func syncDraftTitleIfNeeded(isRenaming: Bool) {
        guard isRenaming else {
            return
        }

        draftTitle = tab.userTitleOverride ?? tab.displayTitle
    }

    @ViewBuilder
    private var copyLinkMenuItem: some View {
        if isSelected {
            Button(BrowserStrings.tabCopyLinkAction, action: onCopyLink)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        } else {
            Button(BrowserStrings.tabCopyLinkAction, action: onCopyLink)
        }
    }

    @ViewBuilder
    private var shareMenuItem: some View {
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

    private var sharingItems: [Any] {
        if let pageURL = tab.pageURL {
            return [pageURL]
        }

        return [NSString(string: tab.urlString)]
    }
}

private enum BrowserShareMenuServiceProvider {
    static func sharingServices(for items: [Any]) -> [NSSharingService] {
        let readingListMenuTitle = NSSharingService(named: .addToSafariReadingList)?.menuItemTitle

        return deprecatedSharingServices(for: items).filter { service in
            guard let readingListMenuTitle else {
                return true
            }

            return service.menuItemTitle != readingListMenuTitle
        }
    }

    /// AppKit's newer picker API exposes a ready-made "Share…" item, not a submenu.
    @available(macOS, deprecated: 13.0)
    private static func deprecatedSharingServices(for items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}

private struct BrowserSidebarDropIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: BrowserChromeLayout.sidebarDropIndicatorThickness / 2, style: .continuous)
            .fill(BrowserChromePalette.sidebarDropIndicator)
            .frame(height: BrowserChromeLayout.sidebarDropIndicatorThickness)
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
        BrowserViewportHostRepresentable(
            hostView: model.hostView,
            leadingCornerRadius: leadingCornerRadius
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrowserChromePalette.shellBackground)
        .overlay {
            if !model.isContextReady {
                ZStack {
                    Rectangle()
                        .fill(BrowserChromePalette.contentBackground)

                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                        Text(BrowserStrings.loadingLaunchingBrowser)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.black.opacity(0.58))
                    }
                }
                .clipShape(contentShape)
            }
        }
    }

    private var leadingCornerRadius: CGFloat {
        model.isSidebarVisible ? BrowserChromeLayout.leadingContentCornerRadius : 0
    }

    private var contentShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: leadingCornerRadius,
                bottomLeading: leadingCornerRadius,
                bottomTrailing: 0,
                topTrailing: 0
            ),
            style: .continuous
        )
    }
}

private struct BrowserViewportHostRepresentable: NSViewRepresentable {
    let hostView: NSView
    let leadingCornerRadius: CGFloat

    func makeNSView(context _: Context) -> BrowserViewportClipView {
        let clipView = BrowserViewportClipView(hostView: hostView)
        clipView.updateLeadingCornerRadius(leadingCornerRadius)
        return clipView
    }

    func updateNSView(_ nsView: BrowserViewportClipView, context _: Context) {
        nsView.update(hostView: hostView)
        nsView.updateLeadingCornerRadius(leadingCornerRadius)
    }
}

private final class BrowserViewportClipView: NSView {
    private let maskedLeadingCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    private var hostedView: NSView

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    init(hostView: NSView) {
        hostedView = hostView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = maskedLeadingCorners
        layer?.masksToBounds = true

        attachHostedViewIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }

    func update(hostView: NSView) {
        guard hostedView !== hostView else {
            attachHostedViewIfNeeded()
            return
        }

        hostedView = hostView
        attachHostedViewIfNeeded()
        needsLayout = true
    }

    func updateLeadingCornerRadius(_ leadingCornerRadius: CGFloat) {
        guard let layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = max(leadingCornerRadius, 0)
        CATransaction.commit()
    }

    private func attachHostedViewIfNeeded() {
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }

        hostedView.autoresizingMask = [.width, .height]
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }
}
