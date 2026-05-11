import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserSidebarTabDragPreviewStore

final class BrowserSidebarTabDragPreviewStore: ObservableObject {
    @Published var preview: BrowserSidebarTabDragPreviewState?

    func begin(_ preview: BrowserSidebarTabDragPreviewState) {
        guard self.preview != preview else {
            return
        }

        self.preview = preview
    }

    func update(location: CGPoint, size: CGSize) {
        guard var preview else {
            return
        }

        guard preview.location != location || preview.size != size else {
            return
        }

        preview.update(location: location, size: size)
        self.preview = preview
    }

    func clear() {
        guard preview != nil else {
            return
        }

        preview = nil
    }
}

// MARK: - BrowserSidebarView

struct BrowserSidebarView: View {
    // MARK: Internal

    let model: BrowserChromeModel
    let snapshot: BrowserSidebarSnapshot
    let extensions: [BrowserExtension]
    let showsWindowControlsInSidebar: Bool
    let isCommandBarPresented: Bool
    let isCurrentPageCommandBarPresented: Bool
    let isSidebarResizing: Bool
    let chromeBackgroundMode: BrowserChromeBackgroundMode
    let onToggleSidebar: () -> Void
    let onURLRowFrameChange: (CGRect?) -> Void

    @State var isClearButtonHovered = false
    @State var isSidebarHovered = false
    @State var renamingSpaceID: String?
    @State var renamingTabID: String?
    @State var draggedTabID: String?
    @State var dropTarget: BrowserSidebarTabDropTarget?
    @StateObject var dragPreviewStore = BrowserSidebarTabDragPreviewStore()
    @State var suppressedTabSelectionAfterDragID: String?
    @State var tabRowInteractionResetID = 0
    @State var rawTabRowFrames = [String: BrowserSidebarTabRowFrame]()
    @State var tabRowFrames = [String: BrowserSidebarTabRowFrame]()
    @State var tabDropRowFrameList = [BrowserSidebarTabRowFrame]()
    @State var rawAppTabFrames = [String: BrowserSidebarAppTabFrame]()
    @State var appTabFrames = [String: BrowserSidebarAppTabFrame]()
    @State var appTabDropFrameList = [BrowserSidebarAppTabFrame]()
    @State var appTabsContainerFrame: CGRect?
    @State var rawEmptySectionFrames = [BrowserSidebarEmptySectionFrame]()
    @State var emptySectionFrames = [BrowserSidebarEmptySectionFrame]()
    @State var topChromeDividerVisibilityBySpaceID = [String: Bool]()
    @State var bottomChromeDividerVisibilityBySpaceID = [String: Bool]()
    @State var isSpacePagerDragging = false
    @State var spacePagerRawDragTranslation: CGFloat = 0
    @State var spacePagerDragTranslation: CGFloat = 0
    @State var renameDismissSuppressedUntil = Date.distantPast

    var displayedSnapshot: BrowserSidebarSnapshot {
        displayedSnapshot(for: snapshot)
    }

    var dropIndicatorFrame: CGRect? {
        BrowserSidebarTabDropIndicatorFrameResolver().frame(
            for: dropTarget,
            rowFrames: tabDropRowFrameList,
            emptySectionFrames: emptySectionFrames,
            horizontalInset: 6,
            thickness: BrowserChromeLayout.sidebarDropIndicatorThickness
        )
    }

    var body: some View {
        let visibleSnapshot = displayedSnapshot
        let renderedSidebarSnapshot = renderedSnapshot(for: visibleSnapshot)
        let appTabs = renderedSidebarSnapshot.appTabs
        let sidebarContentWidth = max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)

        VStack(spacing: 0) {
            VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
                topChrome

                if !appTabs.isEmpty || draggedTabID != nil {
                    appTabsGrid(
                        appTabs,
                        sidebarContentWidth: sidebarContentWidth
                    )
                }
            }
            .zIndex(1)
            .padding(.bottom, BrowserChromeLayout.sidebarSectionSpacing)

            spacePages(
                for: renderedSidebarSnapshot,
                sidebarContentWidth: sidebarContentWidth
            )

            bottomChrome(for: renderedSidebarSnapshot)
        }
        .onPreferenceChange(BrowserSidebarAppTabFramePreferenceKey.self) { frames in
            setAppTabFrames(frames, for: renderedSidebarSnapshot)
        }
        .onPreferenceChange(BrowserSidebarAppTabsContainerFramePreferenceKey.self) { frame in
            setAppTabsContainerFrame(frame, for: renderedSidebarSnapshot)
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                tabDropIndicatorOverlay
                tabDragPreviewOverlay
                tabDragEventMonitor
            }
        }
        .coordinateSpace(name: BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
        .padding(.top, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.leading, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.bottom, BrowserChromeLayout.sidebarOuterPadding)
        .padding(.trailing, BrowserChromeLayout.sidebarOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .browserWindowDragGesture(isEnabled: draggedTabID == nil)
        .overlay {
            BrowserPassthroughInteractionObserver { event, observerView in
                resignRenamingFirstResponderIfNeeded(for: event, in: observerView)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onHover { hovering in
            guard !isSidebarResizing else {
                return
            }

            withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
                isSidebarHovered = hovering
            }
            if !hovering {
                isClearButtonHovered = false
            }
        }
        .onChange(of: isSidebarResizing) { _, isSidebarResizing in
            guard isSidebarResizing else {
                return
            }

            clearTabDragState()
            isClearButtonHovered = false
            isSidebarHovered = false
        }
        .onChange(of: snapshot) { _, snapshot in
            let displayedSidebarSnapshot = displayedSnapshot(for: snapshot)
            let renderedSidebarSnapshot = renderedSnapshot(for: displayedSidebarSnapshot)
            setTabRowFrames(rawTabRowFrames, for: renderedSidebarSnapshot)
            setEmptySectionFrames(rawEmptySectionFrames, for: renderedSidebarSnapshot)
            setAppTabFrames(rawAppTabFrames, for: renderedSidebarSnapshot)
            setAppTabsContainerFrame(appTabsContainerFrame, for: renderedSidebarSnapshot)

            guard let draggedTabID, !snapshot.containsTab(withID: draggedTabID) else {
                return
            }

            clearTabDragState()
        }
        .onDisappear {
            clearTabDragState()
        }
        .background {
            ZStack {
                BrowserChromeBackgroundView(mode: chromeBackgroundMode)

                BrowserWindowDragRegion(isEnabled: draggedTabID == nil)
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissRenamingIfNeeded()
                    })
            }
        }
    }

    var topChrome: some View {
        VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            BrowserSidebarHeaderView(
                canGoBack: snapshot.canGoBack,
                canGoForward: snapshot.canGoForward,
                canStopLoading: snapshot.canStopLoading,
                canReload: snapshot.canReload,
                shortcutStore: model.shortcutStore,
                showsWindowControlsInSidebar: showsWindowControlsInSidebar,
                onToggleSidebar: onToggleSidebar,
                onGoBack: model.goBack,
                onGoForward: model.goForward,
                onStopLoading: model.stopLoadingCurrentTab,
                onReload: model.reloadCurrentTab
            )

            BrowserSidebarCurrentURLRow(
                tab: snapshot.selectedTab,
                extensions: extensions,
                copyLinkShortcut: model.shortcutStore.shortcut(for: .copyLink),
                isSearchPresented: isCurrentPageCommandBarPresented,
                isSidebarResizing: isSidebarResizing,
                chromeBackgroundMode: chromeBackgroundMode,
                onFrameChange: onURLRowFrameChange,
                onOpenSearch: model.presentCurrentPageCommandBar,
                onCopyURL: {
                    model.copySelectedTabLink()
                },
                onRefreshExtensions: model.refreshBrowserExtensions,
                onOpenExtensionsManager: model.openExtensionsManager,
                onOpenExtensionStore: model.openExtensionStore,
                onOpenExtensionDetails: model.openExtensionDetails
            )
        }
    }

    var spacesBar: some View {
        BrowserSidebarSpacesBar(
            spaces: snapshot.spaces,
            selectedSpaceID: snapshot.selectedSpaceID,
            isSidebarResizing: isSidebarResizing,
            onSelectSpace: { spaceID in
                dismissRenamingIfNeeded()
                model.selectSpace(id: spaceID)
            },
            onCreateSpace: {
                dismissRenamingIfNeeded()
                model.createNewSpace()
            }
        )
    }

    var tabDragPreviewOverlay: some View {
        BrowserSidebarTabDragPreviewOverlay(
            store: dragPreviewStore,
            snapshot: snapshot
        )
    }

    @ViewBuilder var tabDragEventMonitor: some View {
        if let draggedTabID {
            BrowserSidebarTabDragEventMonitor(
                tabID: draggedTabID,
                onDragged: updateActiveTabDrag(for:location:),
                onEnded: finishActiveTabDrag(for:location:)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder var tabDropIndicatorOverlay: some View {
        if let dropIndicatorFrame {
            BrowserSidebarDropIndicator()
                .frame(width: dropIndicatorFrame.width, height: dropIndicatorFrame.height)
                .position(x: dropIndicatorFrame.midX, y: dropIndicatorFrame.midY)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .allowsHitTesting(false)
        }
    }

    func bottomChrome(for renderedSidebarSnapshot: BrowserSidebarSnapshot) -> some View {
        VStack(spacing: 0) {
            BrowserSidebarTopChromeDivider(
                isVisible: isBottomChromeDividerVisible(in: renderedSidebarSnapshot)
            )
            Color.clear
                .frame(height: BrowserChromeLayout.sidebarBottomChromeTopSpacing)
            spacesBar
        }
        .background {
            BrowserChromeBackgroundView(mode: chromeBackgroundMode)
        }
        .zIndex(1)
    }

    // MARK: Private

    private func spacePages(
        for renderedSidebarSnapshot: BrowserSidebarSnapshot,
        sidebarContentWidth: CGFloat
    ) -> some View {
        GeometryReader { proxy in
            let pageWidth = max(proxy.size.width, 0)
            let selectedIndex = selectedSpaceIndex(in: renderedSidebarSnapshot) ?? 0

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(Array(renderedSidebarSnapshot.spaces.enumerated()), id: \.element.id) { index, space in
                        if shouldRenderSpacePage(at: index, selectedIndex: selectedIndex) {
                            spacePage(
                                for: space,
                                in: renderedSidebarSnapshot,
                                sidebarContentWidth: sidebarContentWidth
                            )
                            .frame(width: pageWidth)
                        } else {
                            Color.clear
                                .frame(width: pageWidth)
                        }
                    }
                }
                .frame(
                    width: pageWidth * CGFloat(renderedSidebarSnapshot.spaces.count),
                    alignment: .leading
                )
                .offset(x: spacePagerOffset(selectedIndex: selectedIndex, pageWidth: pageWidth))
                .contentShape(Rectangle())
                .simultaneousGesture(
                    spacePagerDragGesture(
                        for: renderedSidebarSnapshot,
                        pageWidth: pageWidth
                    )
                )

                BrowserSpacePagerScrollObserver(
                    isEnabled: renderedSidebarSnapshot.spaces.count > 1
                        && !isSidebarResizing
                        && draggedTabID == nil,
                    onScrollDelta: { delta in
                        updateSpacePagerScroll(
                            by: delta,
                            in: renderedSidebarSnapshot,
                            pageWidth: pageWidth
                        )
                    },
                    onScrollReleased: {
                        finishSpacePagerScroll(
                            in: renderedSidebarSnapshot,
                            pageWidth: pageWidth
                        )
                    },
                    onScrollEnded: {
                        resetSpacePagerDrag()
                    }
                )
                .frame(width: pageWidth, height: proxy.size.height)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: renderedSidebarSnapshot.selectedSpaceID) { _, _ in
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
        }
        .onPreferenceChange(BrowserSidebarTabRowFramePreferenceKey.self) { frames in
            setTabRowFrames(frames, for: renderedSidebarSnapshot)
        }
        .onPreferenceChange(BrowserSidebarEmptySectionFramePreferenceKey.self) { frames in
            setEmptySectionFrames(frames, for: renderedSidebarSnapshot)
        }
        .background {
            BrowserWindowDragRegion(isEnabled: draggedTabID == nil)
                .simultaneousGesture(TapGesture().onEnded {
                    dismissRenamingIfNeeded()
                })
        }
    }

    private func spacePage(
        for space: BrowserChromeModel.Space,
        in renderedSidebarSnapshot: BrowserSidebarSnapshot,
        sidebarContentWidth _: CGFloat
    ) -> some View {
        let spacePinnedTabs = renderedSidebarSnapshot.spacePinnedTabs(in: space.id)
        let temporaryTabs = renderedSidebarSnapshot.temporaryTabs(in: space.id)
        let isPinnedSectionCollapsed = renderedSidebarSnapshot.isPinnedSectionCollapsed(in: space.id)

        return VStack(spacing: BrowserChromeLayout.sidebarSectionSpacing) {
            spaceHeaderRow(for: space, in: renderedSidebarSnapshot)
                .background {
                    BrowserChromeBackgroundView(mode: chromeBackgroundMode)
                }
                .zIndex(2)

            ZStack(alignment: .top) {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: BrowserChromeLayout.sidebarListSpacing) {
                        if !isPinnedSectionCollapsed {
                            if spacePinnedTabs.isEmpty {
                                if draggedTabID != nil {
                                    emptySectionDropZone(for: .spacePinned, spaceID: space.id, height: 0)
                                }
                            } else {
                                ForEach(Array(spacePinnedTabs.enumerated()), id: \.element.id) { index, tab in
                                    sidebarRow(for: tab, in: .spacePinned, sectionIndex: index, spaceID: space.id)
                                }
                            }
                        }

                        if !spacePinnedTabs.isEmpty {
                            BrowserSidebarTemporaryTabsDivider(
                                clearTemporaryTabsDescriptor: model.shortcutStore.descriptor(for: .clearTemporaryTabs),
                                chromeBackgroundMode: chromeBackgroundMode,
                                showsClearButton: isSidebarHovered
                                    && !temporaryTabs.isEmpty
                                    && renderedSidebarSnapshot.selectedSpaceID == space.id,
                                isClearButtonHovered: isClearButtonHovered,
                                onHoverClearButton: { hovering in
                                    guard !isSidebarResizing else {
                                        return
                                    }

                                    isClearButtonHovered = hovering
                                },
                                onClear: {
                                    clearTabDragState()
                                    dismissRenamingIfNeeded()
                                    withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                                        model.clearTemporaryTabs()
                                    }
                                }
                            )
                        }

                        BrowserSidebarNewTabButton(
                            shortcutStore: model.shortcutStore,
                            isCommandBarPresented: isCommandBarPresented,
                            isSidebarResizing: isSidebarResizing,
                            onToggleCommandBar: toggleCommandBar
                        )

                        if temporaryTabs.isEmpty, draggedTabID != nil {
                            emptySectionDropZone(for: .temporary, spaceID: space.id, height: 0)
                        }

                        ForEach(Array(temporaryTabs.enumerated()), id: \.element.id) { index, tab in
                            sidebarRow(for: tab, in: .temporary, sectionIndex: index, spaceID: space.id)
                        }
                    }
                    .animation(
                        BrowserChromeLayout.sidebarTabDropListAnimation,
                        value: isPinnedSectionCollapsed
                    )
                    .animation(
                        BrowserChromeLayout.sidebarTabDropListAnimation,
                        value: spacePinnedTabs.map(\.id)
                    )
                    .animation(
                        BrowserChromeLayout.sidebarTabDropListAnimation,
                        value: temporaryTabs.map(\.id)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollDisabled(isSpacePagerDragging)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y > BrowserChromeLayout.sidebarTopChromeDividerScrollThreshold
                } action: { _, shouldShow in
                    updateTopChromeDividerVisibility(shouldShow, forSpaceID: space.id)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY < geometry.contentSize.height - BrowserChromeLayout
                        .sidebarTopChromeDividerScrollThreshold
                } action: { _, shouldShow in
                    updateBottomChromeDividerVisibility(shouldShow, forSpaceID: space.id)
                }

                BrowserSidebarTopChromeDivider(
                    isVisible: isTopChromeDividerVisible(forSpaceID: space.id)
                )
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func spaceHeaderRow(
        for space: BrowserChromeModel.Space,
        in renderedSidebarSnapshot: BrowserSidebarSnapshot
    ) -> some View {
        BrowserSidebarSpaceHeaderRow(
            space: space,
            isRenaming: renamingSpaceID == space.id,
            isCollapsed: renderedSidebarSnapshot.isPinnedSectionCollapsed(in: space.id),
            hasPinnedTabs: !renderedSidebarSnapshot.spacePinnedTabs(in: space.id).isEmpty,
            isSidebarResizing: isSidebarResizing,
            interactionResetID: tabRowInteractionResetID,
            onToggleCollapsed: {
                dismissRenamingIfNeeded()
                withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                    model.toggleActiveSpacePinnedSectionCollapsed()
                }
            },
            onBeginRename: {
                beginRenamingSpace(id: space.id)
            },
            onCommitRename: { title in
                model.setTitle(title, forSpaceID: space.id)
                renamingSpaceID = nil
            },
            onCancelRename: {
                renamingSpaceID = nil
            },
            onChangeIcon: { systemImageName in
                model.setIcon(systemImageName, forSpaceID: space.id)
            }
        )
    }

    private func appTabsGrid(
        _ appTabs: [BrowserChromeModel.Tab],
        sidebarContentWidth: CGFloat
    ) -> some View {
        BrowserSidebarAppTabsGrid(
            tabs: appTabs,
            draggedTabID: draggedTabID,
            isSidebarResizing: isSidebarResizing,
            sidebarContentWidth: sidebarContentWidth,
            onSelect: { tabID in
                guard suppressedTabSelectionAfterDragID != tabID else {
                    return
                }

                if renamingTabID != tabID {
                    dismissRenamingIfNeeded()
                }
                model.selectTab(id: tabID)
            },
            onDragChanged: updateTabDrag(for:value:),
            onDragEnded: finishTabDrag(for:value:)
        )
    }

    private func sidebarRow(
        for tab: BrowserChromeModel.Tab,
        in section: BrowserSidebarTabSection,
        sectionIndex: Int,
        spaceID: String
    ) -> some View {
        BrowserSidebarRow(
            tab: tab,
            copyLinkDescriptor: model.shortcutStore.descriptor(for: .copyLink),
            archiveTabDescriptor: model.shortcutStore.descriptor(for: .archiveTab),
            isSelected: snapshot.selectedTabID == tab.id && !isCommandBarPresented,
            isRenaming: renamingTabID == tab.id,
            canArchiveTabsBelow: snapshot.archivableTabIDs.contains(tab.id),
            isSidebarResizing: isSidebarResizing,
            interactionResetID: tabRowInteractionResetID,
            onSelect: {
                guard suppressedTabSelectionAfterDragID != tab.id else {
                    return
                }

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
                withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                    model.closeTab(id: tab.id)
                }
            },
            onArchiveTabsBelow: {
                renamingTabID = nil
                withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
                    model.closeTabsBelow(id: tab.id)
                }
            }
        )
        .browserSidebarTabRowFrame(tabID: tab.id, section: section, sectionIndex: sectionIndex, spaceID: spaceID)
        .transition(BrowserChromeLayout.sidebarTabVisibilityTransition)
        .opacity(draggedTabID == tab.id ? 0 : 1)
        .allowsHitTesting(draggedTabID != tab.id)
        .simultaneousGesture(tabDragGesture(for: tab.id))
    }

    private func emptySectionDropZone(
        for section: BrowserSidebarTabSection,
        spaceID: String,
        height: CGFloat = BrowserChromeLayout.sidebarEmptySectionDropZoneHeight
    ) -> some View {
        BrowserSidebarEmptySectionDropZone(
            height: height,
            showsDropIndicator: dropTarget == BrowserSidebarTabDropTarget(
                section: section,
                sectionIndex: 0,
                spaceID: spaceID
            )
        )
        .browserSidebarEmptySectionFrame(section: section, spaceID: spaceID)
    }

    private func selectedSpaceIndex(in snapshot: BrowserSidebarSnapshot) -> Int? {
        guard !snapshot.spaces.isEmpty else {
            return nil
        }

        guard let selectedSpaceID = snapshot.selectedSpaceID else {
            return 0
        }

        return snapshot.spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
    }

    private func shouldRenderSpacePage(at index: Int, selectedIndex: Int) -> Bool {
        abs(index - selectedIndex) <= 2
    }

    private func spacePagerOffset(selectedIndex: Int, pageWidth: CGFloat) -> CGFloat {
        -CGFloat(selectedIndex) * pageWidth + spacePagerDragTranslation
    }

    private func spacePagerDragGesture(
        for snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: BrowserChromeLayout.sidebarTabDragMinimumDistance)
            .onChanged { value in
                updateSpacePagerDrag(value, in: snapshot, pageWidth: pageWidth)
            }
            .onEnded { value in
                finishSpacePagerDrag(value, in: snapshot, pageWidth: pageWidth)
            }
    }

    private func updateSpacePagerDrag(
        _ value: DragGesture.Value,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard
            pageWidth > 0,
            snapshot.spaces.count > 1,
            !isSidebarResizing,
            draggedTabID == nil,
            let selectedIndex = selectedSpaceIndex(in: snapshot)
        else {
            resetSpacePagerDrag()
            return
        }

        guard isSpacePagerDragging || isHorizontalSpacePagerDrag(value) else {
            return
        }

        if !isSpacePagerDragging {
            dismissRenamingIfNeeded()
            isSpacePagerDragging = true
        }

        withoutSidebarDragAnimation {
            spacePagerRawDragTranslation = value.translation.width
            spacePagerDragTranslation = constrainedSpacePagerTranslation(
                spacePagerRawDragTranslation,
                selectedIndex: selectedIndex,
                spaceCount: snapshot.spaces.count,
                pageWidth: pageWidth
            )
        }
    }

    private func finishSpacePagerDrag(
        _ value: DragGesture.Value,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard isSpacePagerDragging else {
            resetSpacePagerDrag()
            return
        }

        let targetSpaceID = targetSpaceID(for: value, in: snapshot, pageWidth: pageWidth)
        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
            if let targetSpaceID {
                model.selectSpace(id: targetSpaceID)
            }
        }
    }

    private func updateSpacePagerScroll(
        by delta: CGFloat,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard
            pageWidth > 0,
            snapshot.spaces.count > 1,
            !isSidebarResizing,
            draggedTabID == nil,
            let selectedIndex = selectedSpaceIndex(in: snapshot)
        else {
            resetSpacePagerDrag()
            return
        }

        if !isSpacePagerDragging {
            dismissRenamingIfNeeded()
            isSpacePagerDragging = true
        }

        withoutSidebarDragAnimation {
            spacePagerRawDragTranslation += delta
            spacePagerDragTranslation = constrainedSpacePagerTranslation(
                spacePagerRawDragTranslation,
                selectedIndex: selectedIndex,
                spaceCount: snapshot.spaces.count,
                pageWidth: pageWidth
            )
        }
    }

    private func finishSpacePagerScroll(
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard isSpacePagerDragging else {
            resetSpacePagerDrag()
            return
        }

        let targetSpaceID = targetSpaceID(
            forProjectedTranslation: spacePagerRawDragTranslation,
            in: snapshot,
            pageWidth: pageWidth
        )
        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
            if let targetSpaceID {
                model.selectSpace(id: targetSpaceID)
            }
        }
    }

    private func resetSpacePagerDrag() {
        guard isSpacePagerDragging || spacePagerRawDragTranslation != 0 || spacePagerDragTranslation != 0 else {
            return
        }

        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
        }
    }

    private func isHorizontalSpacePagerDrag(_ value: DragGesture.Value) -> Bool {
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        return horizontal > max(vertical * 1.25, BrowserChromeLayout.sidebarTabDragMinimumDistance * 2)
    }

    private func constrainedSpacePagerTranslation(
        _ translation: CGFloat,
        selectedIndex: Int,
        spaceCount: Int,
        pageWidth: CGFloat
    ) -> CGFloat {
        guard pageWidth > 0, translation != 0 else {
            return 0
        }

        let direction: CGFloat = translation > 0 ? 1 : -1
        let magnitude = abs(translation)
        let canMoveToAdjacentSpace = direction > 0
            ? selectedIndex > 0
            : selectedIndex < spaceCount - 1
        let pageLimit = canMoveToAdjacentSpace ? pageWidth : 0

        guard magnitude > pageLimit else {
            return translation
        }

        let overscrollLimit = pageWidth * (canMoveToAdjacentSpace ? 0.2 : 0.14)
        let resistedOverflow = rubberBandDistance(
            magnitude - pageLimit,
            limit: overscrollLimit
        )
        return direction * (pageLimit + resistedOverflow)
    }

    private func targetSpaceID(
        for value: DragGesture.Value,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) -> String? {
        guard
            pageWidth > 0,
            let selectedIndex = selectedSpaceIndex(in: snapshot)
        else {
            return nil
        }

        let projectedTranslation = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
            ? value.predictedEndTranslation.width
            : value.translation.width
        return targetSpaceID(
            forProjectedTranslation: projectedTranslation,
            in: snapshot,
            pageWidth: pageWidth
        )
    }

    private func targetSpaceID(
        forProjectedTranslation projectedTranslation: CGFloat,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) -> String? {
        guard
            pageWidth > 0,
            let selectedIndex = selectedSpaceIndex(in: snapshot)
        else {
            return nil
        }

        let threshold = max(min(pageWidth * 0.28, 140), 48)
        let targetIndex: Int? =
            if projectedTranslation <= -threshold {
                selectedIndex + 1
            } else if projectedTranslation >= threshold {
                selectedIndex - 1
            } else {
                nil
            }

        guard
            let targetIndex,
            snapshot.spaces.indices.contains(targetIndex)
        else {
            return nil
        }

        return snapshot.spaces[targetIndex].id
    }

    private func rubberBandDistance(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard distance > 0, limit > 0 else {
            return 0
        }

        return limit * (1 - exp(-distance / limit))
    }

    private func displayedSnapshot(for snapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
        guard
            let draggedTabID,
            let dropTarget,
            let reorderedTabs = model.reorderedTabs(
                movingTabID: draggedTabID,
                toPlacement: dropTarget.section.placement,
                requestedSectionIndex: dropTarget.sectionIndex,
                targetSpaceID: dropTarget.spaceID
            )
        else {
            return snapshot
        }

        return snapshot.replacingTabs(reorderedTabs)
    }

    private func renderedSnapshot(for visibleSnapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
        guard
            let draggedTabID,
            let draggedTab = snapshot.tab(withID: draggedTabID)
        else {
            return visibleSnapshot
        }

        return BrowserSidebarSnapshot(
            spaces: visibleSnapshot.spaces,
            selectedSpaceID: visibleSnapshot.selectedSpaceID,
            activeSpace: visibleSnapshot.activeSpace,
            isActiveSpacePinnedSectionCollapsed: visibleSnapshot.isActiveSpacePinnedSectionCollapsed,
            allTabs: renderedAllTabs(in: visibleSnapshot, draggedTab: draggedTab),
            appTabs: renderedAppTabs(visibleSnapshot.appTabs, draggedTab: draggedTab),
            spacePinnedTabs: renderedRowTabs(
                visibleSnapshot.spacePinnedTabs,
                in: .spacePinned,
                draggedTab: draggedTab
            ),
            temporaryTabs: renderedRowTabs(
                visibleSnapshot.temporaryTabs,
                in: .temporary,
                draggedTab: draggedTab
            ),
            selectedTabID: visibleSnapshot.selectedTabID,
            archivableTabIDs: visibleSnapshot.archivableTabIDs,
            canGoBack: visibleSnapshot.canGoBack,
            canGoForward: visibleSnapshot.canGoForward,
            canStopLoading: visibleSnapshot.canStopLoading,
            canReload: visibleSnapshot.canReload
        )
    }

    private func renderedAllTabs(
        in visibleSnapshot: BrowserSidebarSnapshot,
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        guard
            let dropTarget,
            dropTarget.section.placement != .app,
            let targetSpaceID = dropTarget.spaceID,
            draggedTab.placement != dropTarget.section.placement || draggedTab.spaceID != targetSpaceID,
            visibleSnapshot.allTabs.contains(where: { $0.id == draggedTab.id })
        else {
            return visibleSnapshot.allTabs
        }

        var renderedTabs = visibleSnapshot.allTabs.filter { $0.id != draggedTab.id }
        var renderedTab = draggedTab
        renderedTab.spaceID = targetSpaceID
        renderedTab.placement = dropTarget.section.placement

        let targetTabs = renderedTabs.filter {
            $0.spaceID == targetSpaceID && $0.placement == dropTarget.section.placement
        }
        let insertionReferenceIndex = targetTabs.dropFirst(
            min(max(dropTarget.sectionIndex, 0), targetTabs.count)
        )
        .first
        .flatMap { referenceTab in
            renderedTabs.firstIndex { $0.id == referenceTab.id }
        }

        renderedTabs.insert(renderedTab, at: insertionReferenceIndex ?? renderedTabs.count)
        return renderedTabs
    }

    private func renderedAppTabs(
        _ visibleTabs: [BrowserChromeModel.Tab],
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        guard draggedTab.placement == .app, !visibleTabs.contains(where: { $0.id == draggedTab.id }) else {
            return visibleTabs
        }

        var renderedTabs = visibleTabs
        let sourceIndex = snapshot.appTabs.firstIndex(where: { $0.id == draggedTab.id }) ?? renderedTabs.count
        renderedTabs.insert(draggedTab, at: min(sourceIndex, renderedTabs.count))
        return renderedTabs
    }

    private func renderedRowTabs(
        _ visibleTabs: [BrowserChromeModel.Tab],
        in section: BrowserSidebarTabSection,
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        var renderedTabs = visibleTabs

        if section == .spacePinned, draggedTab.placement != section.placement {
            renderedTabs.removeAll { $0.id == draggedTab.id }
        }

        guard draggedTab.placement == section.placement,
              !renderedTabs.contains(where: { $0.id == draggedTab.id })
        else {
            return renderedTabs
        }

        let sourceTabs = tabs(in: section, from: snapshot)
        let sourceIndex = sourceTabs.firstIndex(where: { $0.id == draggedTab.id }) ?? renderedTabs.count
        renderedTabs.insert(draggedTab, at: min(sourceIndex, renderedTabs.count))
        return renderedTabs
    }

    private func tabs(
        in section: BrowserSidebarTabSection,
        from snapshot: BrowserSidebarSnapshot
    ) -> [BrowserChromeModel.Tab] {
        switch section {
        case .app:
            snapshot.appTabs
        case .spacePinned:
            snapshot.spacePinnedTabs
        case .temporary:
            snapshot.temporaryTabs
        }
    }

    private func toggleCommandBar() {
        dismissRenamingIfNeeded()
        model.toggleCommandBar()
    }

    private func dismissRenamingIfNeeded(in window: NSWindow? = NSApp.keyWindow) {
        guard renamingTabID != nil || renamingSpaceID != nil else {
            return
        }

        let activeRenamingTabID = renamingTabID
        let activeRenamingSpaceID = renamingSpaceID
        window?.makeFirstResponder(nil)

        DispatchQueue.main.async {
            guard renamingTabID == activeRenamingTabID, renamingSpaceID == activeRenamingSpaceID else {
                return
            }

            renamingTabID = nil
            renamingSpaceID = nil
        }
    }

    private func resignRenamingFirstResponderIfNeeded(for event: NSEvent, in observerView: NSView) {
        guard renamingTabID != nil || renamingSpaceID != nil,
              Date() >= renameDismissSuppressedUntil,
              let window = observerView.window,
              !isEventInsideSidebarRenameTextField(event, in: window)
        else {
            return
        }

        dismissRenamingIfNeeded(in: window)
    }

    private func isEventInsideSidebarRenameTextField(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else {
            return false
        }

        return contentView.containsWindowPoint(
            event.locationInWindow,
            inDescendantOfType: BrowserSidebarRenameNSTextField.self
        )
    }

    private func beginRenamingTab(id tabID: String) {
        let shouldDeferRenameActivation = renamingSpaceID != nil || (renamingTabID != nil && renamingTabID != tabID)
        suppressRenameDismissalDuringActivation()

        if renamingSpaceID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingTabID, renamingTabID != tabID {
            dismissRenamingIfNeeded()
        }

        if shouldDeferRenameActivation {
            DispatchQueue.main.async {
                renamingTabID = tabID
            }
        } else {
            renamingTabID = tabID
        }
    }

    private func beginRenamingSpace(id spaceID: String) {
        let shouldDeferRenameActivation = renamingTabID != nil || (renamingSpaceID != nil && renamingSpaceID != spaceID)
        suppressRenameDismissalDuringActivation()

        if renamingTabID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingSpaceID, renamingSpaceID != spaceID {
            dismissRenamingIfNeeded()
        }

        if shouldDeferRenameActivation {
            DispatchQueue.main.async {
                renamingSpaceID = spaceID
            }
        } else {
            renamingSpaceID = spaceID
        }
    }

    private func suppressRenameDismissalDuringActivation() {
        renameDismissSuppressedUntil = Date()
            .addingTimeInterval(BrowserChromeLayout.sidebarRenameActivationGraceInterval)
    }

    private func tabDragGesture(for tabID: String) -> some Gesture {
        DragGesture(
            minimumDistance: BrowserChromeLayout.sidebarTabDragMinimumDistance,
            coordinateSpace: .named(BrowserChromeLayout.sidebarTabDragCoordinateSpaceName)
        )
        .onChanged { value in
            updateTabDrag(for: tabID, value: value)
        }
        .onEnded { value in
            finishTabDrag(for: tabID, value: value)
        }
    }

    private func updateTabDrag(for tabID: String, value: DragGesture.Value) {
        guard suppressedTabSelectionAfterDragID != tabID else {
            clearTabDragState()
            return
        }

        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        beginTabDragIfNeeded(for: tabID, startLocation: value.startLocation, location: value.location)
        let target = resolvedTabDropTarget(at: value.location)
        setDropTarget(target)
        updateDragPreviewLocation(value.location, target: target)
    }

    private func updateActiveTabDrag(for tabID: String, location: CGPoint) {
        guard draggedTabID == tabID else {
            return
        }

        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        let target = resolvedTabDropTarget(at: location)
        setDropTarget(target)
        updateDragPreviewLocation(location, target: target)
    }

    private func finishTabDrag(for tabID: String, value: DragGesture.Value) {
        guard draggedTabID == tabID else {
            clearTabDragState()
            return
        }

        suppressSelectionAfterDrag(for: tabID)

        let target = resolvedTabDropTarget(at: value.location)
        setDropTarget(target)
        updateDragPreviewLocation(value.location, target: target)

        if let target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    private func finishActiveTabDrag(for tabID: String, location: CGPoint) {
        guard draggedTabID == tabID else {
            return
        }

        suppressSelectionAfterDrag(for: tabID)

        let target = resolvedTabDropTarget(at: location)
        setDropTarget(target)
        updateDragPreviewLocation(location, target: target)

        if let target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    private func beginTabDragIfNeeded(for tabID: String, startLocation: CGPoint, location: CGPoint) {
        guard draggedTabID != tabID else {
            return
        }

        dismissRenamingIfNeeded()
        draggedTabID = tabID
        withoutSidebarDragAnimation {
            dragPreviewStore.begin(
                BrowserSidebarTabDragPreviewState(
                    tabID: tabID,
                    sourceFrame: dragPreviewSourceFrame(for: tabID, startLocation: startLocation),
                    location: location
                )
            )
        }
        suppressedTabSelectionAfterDragID = nil
        setDropTarget(nil)
    }

    private func updateDragPreviewLocation(_ location: CGPoint, target: BrowserSidebarTabDropTarget?) {
        dragPreviewStore.update(location: location, size: dragPreviewSize(for: target))
    }

    private func dragPreviewSourceFrame(for tabID: String, startLocation: CGPoint) -> CGRect {
        if let frame = appTabFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        if let frame = tabRowFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        let fallbackWidth = max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)
        return CGRect(
            x: 0,
            y: startLocation.y - BrowserChromeLayout.sidebarRowHeight / 2,
            width: fallbackWidth,
            height: BrowserChromeLayout.sidebarRowHeight
        )
    }

    private func dragPreviewSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        guard target?.section == .app else {
            return dragPreviewRowSize(for: target)
        }

        return dragPreviewAppTileSize(for: target)
    }

    private func dragPreviewRowSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        if
            let target,
            target.section != .app,
            let frame = dragPreviewRowFrame(for: target)
        {
            return CGSize(width: frame.width, height: BrowserChromeLayout.sidebarRowHeight)
        }

        if let draggedTabID, let frame = tabRowFrames[draggedTabID]?.frame, !frame.isEmpty {
            return frame.size
        }

        return CGSize(
            width: max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0),
            height: BrowserChromeLayout.sidebarRowHeight
        )
    }

    private func dragPreviewRowFrame(for target: BrowserSidebarTabDropTarget) -> CGRect? {
        let sectionFrames = tabDropRowFrameList.filter {
            $0.section == target.section && $0.spaceID == target.spaceID
        }
        if let targetFrame = sectionFrames.first(where: { $0.sectionIndex == target.sectionIndex })?.frame {
            return targetFrame
        }

        if let previousFrame = sectionFrames.first(where: { $0.sectionIndex == target.sectionIndex - 1 })?.frame {
            return previousFrame
        }

        if let sectionFrame = sectionFrames.first?.frame {
            return sectionFrame
        }

        return emptySectionFrames.first {
            $0.section == target.section && $0.spaceID == target.spaceID
        }?.frame
    }

    private func dragPreviewAppTileSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        if
            let draggedTabID,
            let frame = appTabDropFrameList.first(where: { $0.tabID == draggedTabID })?.frame
        {
            return frame.size
        }

        let sectionIndex = min(max(target?.sectionIndex ?? 0, 0), max(appTabDropFrameList.count - 1, 0))
        if appTabDropFrameList.indices.contains(sectionIndex) {
            return appTabDropFrameList[sectionIndex].frame.size
        }

        let proposedFrameCount = proposedAppTabCountForDrag()
        return BrowserSidebarAppTabGridLayout(
            spacing: BrowserChromeLayout.appTabGridSpacing
        )
        .frames(
            for: proposedFrameCount,
            availableWidth: max(model.sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)
        )
        .dropFirst(min(max(target?.sectionIndex ?? 0, 0), max(proposedFrameCount - 1, 0)))
        .first?
        .size ?? CGSize(width: BrowserChromeLayout.sidebarRowHeight, height: BrowserChromeLayout.sidebarRowHeight)
    }

    private func proposedAppTabCountForDrag() -> Int {
        guard
            let draggedTabID,
            let draggedTab = snapshot.tab(withID: draggedTabID)
        else {
            return max(snapshot.appTabs.count, 1)
        }

        let proposedCount = snapshot.appTabs.count + (draggedTab.placement == .app ? 0 : 1)
        return min(max(proposedCount, 1), BrowserSidebarAppTabGridLayout.capacity)
    }

    private func resolvedTabDropTarget(at location: CGPoint) -> BrowserSidebarTabDropTarget? {
        BrowserSidebarTabDragTargetResolver(
            verticalSnapDistance: BrowserChromeLayout.sidebarTabDropVerticalSnapDistance,
            horizontalTolerance: BrowserChromeLayout.sidebarTabDropHorizontalTolerance
        )
        .target(
            for: location,
            rowFrames: tabDropRowFrameList,
            emptySectionFrames: emptySectionFrames,
            appTabFrames: appTabDropFrameList,
            appTabContainerFrame: appTabsContainerFrame,
            canMoveToTarget: canMoveDraggedTab(to:)
        )
    }

    private func setTabRowFrames(
        _ frames: [String: BrowserSidebarTabRowFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawTabRowFrames = frames
        updateSynchronizedTabFrames(for: snapshot)
    }

    private func updateSynchronizedTabFrames(for snapshot: BrowserSidebarSnapshot) {
        var synchronizedFrames = [String: BrowserSidebarTabRowFrame]()
        var synchronizedDropFrames = [BrowserSidebarTabRowFrame]()

        for space in snapshot.spaces {
            let spacePinnedTabIDs = snapshot.isPinnedSectionCollapsed(in: space.id)
                ? []
                : snapshot.spacePinnedTabs(in: space.id).map(\.id)
            let temporaryTabIDs = snapshot.temporaryTabs(in: space.id).map(\.id)

            synchronizedFrames.merge(
                BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
                    rawTabRowFrames,
                    spacePinnedTabIDs: spacePinnedTabIDs,
                    temporaryTabIDs: temporaryTabIDs,
                    spaceID: space.id
                )
            ) { _, newValue in newValue }

            synchronizedDropFrames.append(
                contentsOf: BrowserSidebarTabFrameSynchronizer.synchronizedDropRowFrameList(
                    rawTabRowFrames,
                    fallbackRowFrames: tabDropRowFrameList,
                    emptySectionFrames: rawEmptySectionFrames,
                    spacePinnedTabIDs: spacePinnedTabIDs,
                    temporaryTabIDs: temporaryTabIDs,
                    rowHeight: BrowserChromeLayout.sidebarRowHeight,
                    rowSpacing: BrowserChromeLayout.sidebarListSpacing,
                    spaceID: space.id
                )
            )
        }

        tabRowFrames = synchronizedFrames
        tabDropRowFrameList = synchronizedDropFrames
    }

    private func setAppTabFrames(
        _ frames: [String: BrowserSidebarAppTabFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawAppTabFrames = frames
        updateSynchronizedAppTabFrames(for: snapshot)
    }

    private func setAppTabsContainerFrame(
        _ frame: CGRect?,
        for snapshot: BrowserSidebarSnapshot
    ) {
        appTabsContainerFrame = frame
        updateSynchronizedAppTabFrames(for: snapshot)
    }

    private func updateSynchronizedAppTabFrames(for snapshot: BrowserSidebarSnapshot) {
        let appTabIDs = snapshot.appTabs.map(\.id)
        appTabFrames = BrowserSidebarAppTabFrameSynchronizer.synchronizedFrames(
            rawAppTabFrames,
            appTabIDs: appTabIDs
        )
        appTabDropFrameList = BrowserSidebarAppTabFrameSynchronizer.dropFrameList(
            containerFrame: appTabsContainerFrame,
            appTabIDs: appTabIDs,
            spacing: BrowserChromeLayout.appTabGridSpacing
        )
    }

    private func setEmptySectionFrames(
        _ frames: [BrowserSidebarEmptySectionFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawEmptySectionFrames = frames
        emptySectionFrames = snapshot.spaces.flatMap { space in
            BrowserSidebarTabFrameSynchronizer.synchronizedEmptySectionFrames(
                frames,
                spacePinnedTabIDs: snapshot.isPinnedSectionCollapsed(in: space.id)
                    ? []
                    : snapshot.spacePinnedTabs(in: space.id).map(\.id),
                temporaryTabIDs: snapshot.temporaryTabs(in: space.id).map(\.id),
                spaceID: space.id
            )
        }
        updateSynchronizedTabFrames(for: snapshot)
    }

    private func isTopChromeDividerVisible(forSpaceID spaceID: String) -> Bool {
        topChromeDividerVisibilityBySpaceID[spaceID] ?? false
    }

    private func isBottomChromeDividerVisible(in snapshot: BrowserSidebarSnapshot) -> Bool {
        guard let selectedSpaceID = snapshot.selectedSpaceID else {
            return false
        }

        return bottomChromeDividerVisibilityBySpaceID[selectedSpaceID] ?? false
    }

    private func updateTopChromeDividerVisibility(_ shouldShow: Bool, forSpaceID spaceID: String) {
        guard topChromeDividerVisibilityBySpaceID[spaceID, default: false] != shouldShow else {
            return
        }

        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            topChromeDividerVisibilityBySpaceID[spaceID] = shouldShow
        }
    }

    private func updateBottomChromeDividerVisibility(_ shouldShow: Bool, forSpaceID spaceID: String) {
        guard bottomChromeDividerVisibilityBySpaceID[spaceID, default: false] != shouldShow else {
            return
        }

        withAnimation(.easeInOut(duration: BrowserChromeLayout.sidebarAnimationDuration)) {
            bottomChromeDividerVisibilityBySpaceID[spaceID] = shouldShow
        }
    }

    private func setDropTarget(_ target: BrowserSidebarTabDropTarget?) {
        guard dropTarget != target else {
            return
        }

        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            dropTarget = target
        }

        if target != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func suppressSelectionAfterDrag(for tabID: String) {
        suppressedTabSelectionAfterDragID = tabID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard suppressedTabSelectionAfterDragID == tabID else {
                return
            }

            suppressedTabSelectionAfterDragID = nil
        }
    }

    private func canMoveDraggedTab(to target: BrowserSidebarTabDropTarget) -> Bool {
        guard let draggedTabID else {
            return false
        }

        return model.canMoveTab(
            withID: draggedTabID,
            toPlacement: target.section.placement,
            atSectionIndex: target.sectionIndex,
            targetSpaceID: target.spaceID
        )
    }

    private func moveDraggedTab(to target: BrowserSidebarTabDropTarget) {
        guard let draggedTabID else {
            return
        }

        dismissRenamingIfNeeded()
        clearTabDragState()

        withAnimation(BrowserChromeLayout.sidebarTabDropListAnimation) {
            model.moveTab(
                withID: draggedTabID,
                toPlacement: target.section.placement,
                atSectionIndex: target.sectionIndex,
                targetSpaceID: target.spaceID
            )
        }
    }

    private func clearTabDragState() {
        let hadTabDragState = draggedTabID != nil || dropTarget != nil || dragPreviewStore.preview != nil
        draggedTabID = nil
        dropTarget = nil
        dragPreviewStore.clear()

        if hadTabDragState {
            tabRowInteractionResetID += 1
        }
    }

    private func withoutSidebarDragAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }
}

// MARK: Equatable

extension BrowserSidebarView: Equatable {
    static func == (lhs: BrowserSidebarView, rhs: BrowserSidebarView) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.extensions == rhs.extensions
            && lhs.showsWindowControlsInSidebar == rhs.showsWindowControlsInSidebar
            && lhs.isCommandBarPresented == rhs.isCommandBarPresented
            && lhs.isCurrentPageCommandBarPresented == rhs.isCurrentPageCommandBarPresented
            && lhs.isSidebarResizing == rhs.isSidebarResizing
    }
}
