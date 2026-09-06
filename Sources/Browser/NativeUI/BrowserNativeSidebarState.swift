import AppKit
import Combine

/// Sidebar interaction state, kept independent of its view hierarchy. Drop proposals use the existing slot resolver.
@MainActor final class BrowserNativeSidebarState {
    // MARK: Lifecycle

    init(model: BrowserChromeModel, snapshot: BrowserSidebarSnapshot, sidebarWidth: CGFloat) {
        self.model = model
        self.snapshot = snapshot
        self.sidebarWidth = sidebarWidth
        updateRevealedPinnedFolderTabs(for: snapshot)
        self.previewObservation = dragPreviewStore.objectWillChange.sink { [weak self] in self?.invalidate() }
    }

    // MARK: Internal

    let model: BrowserChromeModel
    private(set) var snapshot: BrowserSidebarSnapshot
    var sidebarWidth: CGFloat
    var isSidebarResizing = false
    var onChange: (Bool) -> Void = { _ in }
    var draggedTabIDs = Set<String>() { didSet { invalidate() } }
    var tabDragSession: BrowserSidebarTabDragSession?
    var dragPreviewStore = BrowserSidebarTabDragPreviewStore()
    var suppressedTabSelectionAfterDragID: String?
    var selectedPinnedTabIDs = Set<String>() { didSet { invalidate() } }
    var pinnedTabSelectionAnchorID: String?
    var rawTabRowFrames = [String: BrowserSidebarTabRowFrame]()
    var tabRowFrames = [String: BrowserSidebarTabRowFrame]()
    var tabDropRowFrameList = [BrowserSidebarTabRowFrame]()
    var pinnedFolderRowFrames = [BrowserSidebarPinnedFolderRowFrame]()
    var spaceHeaderFrames = [BrowserSidebarSpaceHeaderFrame]()
    var rawAppTabFrames = [String: BrowserSidebarAppTabFrame]()
    var appTabFrames = [String: BrowserSidebarAppTabFrame]()
    var appTabDropFrameList = [BrowserSidebarAppTabFrame]()
    var appTabsContainerFrame: CGRect?
    var rawEmptySectionFrames = [BrowserSidebarEmptySectionFrame]()
    var emptySectionFrames = [BrowserSidebarEmptySectionFrame]()
    var spacePagerRawDragTranslation: CGFloat = 0
    var renameDismissSuppressedUntil = Date.distantPast

    var isDraggingSidebarItem: Bool {
        draggedTabID != nil || !draggedTabIDs.isEmpty || draggedPinnedFolderID != nil
    }

    var isClearButtonHovered = false { didSet { invalidate() } }
    var activeTemporaryTabClearConfirmationTabID: String? { didSet { invalidate() } }
    var isSidebarHovered = false { didSet { invalidate() } }
    var renamingSpaceID: String? { didSet { invalidate() } }
    var renamingTabID: String? { didSet { invalidate() } }
    var renamingPinnedTabFolderID: String? { didSet { invalidate() } }
    var draggedTabID: String? { didSet { invalidate() } }
    var draggedPinnedFolderID: String? { didSet { invalidate() } }
    var dropProposal: BrowserSidebarTabDropProposal? { didSet { invalidate() } }
    var revealedPinnedFolderTabIDsByFolderID = [String: Set<String>]() { didSet { invalidate() } }
    var tabRowInteractionResetID = 0 { didSet { invalidate() } }
    var topChromeDividerVisibilityBySpaceID = [String: Bool]() { didSet { invalidate() } }
    var bottomChromeDividerVisibilityBySpaceID = [String: Bool]() { didSet { invalidate() } }
    var isSpacePagerDragging = false { didSet { invalidate() } }
    var spacePagerDragTranslation: CGFloat = 0 { didSet { invalidate() } }

    func invalidate(animated: Bool = false) {
        shouldAnimate = shouldAnimate || animated
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let animated = shouldAnimate
            updateScheduled = false
            shouldAnimate = false
            onChange(animated)
        }
    }

    func withSidebarAnimation<T>(_ updates: () -> T) -> T {
        let result = updates()
        invalidate(animated: true)
        return result
    }

    func update(snapshot newSnapshot: BrowserSidebarSnapshot, sidebarWidth: CGFloat, isResizing: Bool) {
        self.sidebarWidth = sidebarWidth
        if isSidebarResizing != isResizing {
            isSidebarResizing = isResizing
            if isResizing {
                clearTabDragState()
                isClearButtonHovered = false
                isSidebarHovered = false
            }
        }
        guard newSnapshot != snapshot else { return }
        if newSnapshot.selectedSpaceID != snapshot.selectedSpaceID {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
            activeTemporaryTabClearConfirmationTabID = nil
        }
        if newSnapshot.selectedTabID != snapshot.selectedTabID,
           activeTemporaryTabClearConfirmationTabID != newSnapshot.selectedTabID
        {
            activeTemporaryTabClearConfirmationTabID = nil
        }
        snapshot = newSnapshot
        updateRevealedPinnedFolderTabs(for: snapshot)
        let rendered = renderedSnapshot(for: snapshot)
        setTabRowFrames(rawTabRowFrames, for: rendered)
        setEmptySectionFrames(rawEmptySectionFrames, for: rendered)
        setAppTabFrames(rawAppTabFrames, for: rendered)
        setAppTabsContainerFrame(appTabsContainerFrame, for: rendered)
        selectedPinnedTabIDs.formIntersection(Set(snapshot.spacePinnedTabs.map(\.id)))
        if let draggedTabID, !snapshot.containsTab(withID: draggedTabID) {
            clearTabDragState()
        }
        if let draggedPinnedFolderID,
           snapshot.pinnedTabFolder(withID: draggedPinnedFolderID) == nil
        {
            clearTabDragState()
        }
    }

    func clearTemporaryTabs(in spaceID: String) {
        let tabs = snapshot.temporaryTabs(in: spaceID)
        let activeID = tabs.contains { $0.id == snapshot.selectedTabID } ? snapshot.selectedTabID : nil
        let includesActive = tabs
            .count == 1 || (activeID != nil && activeTemporaryTabClearConfirmationTabID == activeID)
        clearTabDragState()
        dismissRenamingIfNeeded()
        withSidebarAnimation {
            model.clearTemporaryTabs(includingActiveTab: includesActive)
            activeTemporaryTabClearConfirmationTabID = includesActive ? nil : activeID
        }
    }

    func isPinnedFolderDropTarget(folderID: String) -> Bool {
        guard
            let proposal = dropProposal,
            proposal.indicatorFrame == nil,
            proposal.target.section == .spacePinned
        else {
            return false
        }

        return proposal.target.pinnedFolderID == folderID
    }

    func isSpaceHeaderDropTarget(spaceID: String) -> Bool {
        guard
            let proposal = dropProposal,
            proposal.indicatorFrame == nil,
            proposal.target.section == .spacePinned,
            proposal.target.sectionIndex == 0,
            proposal.target.spaceID == spaceID,
            proposal.target.pinnedFolderID == nil
        else {
            return false
        }

        return true
    }

    func selectedSpaceIndex(in snapshot: BrowserSidebarSnapshot) -> Int? {
        guard !snapshot.spaces.isEmpty else {
            return nil
        }

        guard let selectedSpaceID = snapshot.selectedSpaceID else {
            return 0
        }

        return snapshot.spaces.firstIndex { $0.id == selectedSpaceID } ?? 0
    }

    func shouldRenderSpacePage(at index: Int, selectedIndex: Int) -> Bool {
        abs(index - selectedIndex) <= 2
    }

    func spacePagerOffset(selectedIndex: Int, pageWidth: CGFloat) -> CGFloat {
        -CGFloat(selectedIndex) * pageWidth + spacePagerDragTranslation
    }

    func updateSpacePagerDrag(
        _ value: BrowserNativeDragValue,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard
            pageWidth > 0,
            snapshot.spaces.count > 1,
            !isSidebarResizing,
            !isDraggingSidebarItem,
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

    func finishSpacePagerDrag(
        _ value: BrowserNativeDragValue,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard isSpacePagerDragging else {
            resetSpacePagerDrag()
            return
        }

        let targetSpaceID = targetSpaceID(for: value, in: snapshot, pageWidth: pageWidth)
        withSidebarAnimation {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
            if let targetSpaceID {
                model.selectSpace(id: targetSpaceID)
            }
        }
    }

    func updateSpacePagerScroll(
        by delta: CGFloat,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) {
        guard
            pageWidth > 0,
            snapshot.spaces.count > 1,
            !isSidebarResizing,
            !isDraggingSidebarItem,
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

    func finishSpacePagerScroll(
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
        withSidebarAnimation {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
            if let targetSpaceID {
                model.selectSpace(id: targetSpaceID)
            }
        }
    }

    func resetSpacePagerDrag() {
        guard isSpacePagerDragging || spacePagerRawDragTranslation != 0 || spacePagerDragTranslation != 0 else {
            return
        }

        withSidebarAnimation {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
        }
    }

    func isHorizontalSpacePagerDrag(_ value: BrowserNativeDragValue) -> Bool {
        let horizontal = abs(value.translation.width)
        let vertical = abs(value.translation.height)
        return horizontal > max(vertical * 1.25, BrowserChromeLayout.sidebarTabDragMinimumDistance * 2)
    }

    func constrainedSpacePagerTranslation(
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

    func targetSpaceID(
        for value: BrowserNativeDragValue,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat
    ) -> String? {
        guard
            pageWidth > 0,
            selectedSpaceIndex(in: snapshot) != nil
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

    func targetSpaceID(
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

    func rubberBandDistance(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        guard distance > 0, limit > 0 else {
            return 0
        }

        return limit * (1 - exp(-distance / limit))
    }

    func displayedSnapshot(for snapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
        snapshot
    }

    func renderedSnapshot(for visibleSnapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
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
            allTabs: visibleSnapshot.allTabs,
            pinnedTabFolders: visibleSnapshot.pinnedTabFolders,
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

    func renderedAppTabs(
        _ visibleTabs: [BrowserChromeModel.Tab],
        draggedTab: BrowserChromeModel.Tab
    ) -> [BrowserChromeModel.Tab] {
        if let dropTarget = dropProposal?.target,
           dropTarget.section == .app,
           let reorderedTabs = model.reorderedTabs(
               movingTabID: draggedTab.id,
               toPlacement: .app,
               requestedSectionIndex: dropTarget.sectionIndex
           )
        {
            return reorderedTabs.filter { $0.placement == .app }
        }

        guard draggedTab.placement == .app, !visibleTabs.contains(where: { $0.id == draggedTab.id }) else {
            return visibleTabs
        }

        var renderedTabs = visibleTabs
        let sourceIndex = snapshot.appTabs.firstIndex(where: { $0.id == draggedTab.id }) ?? renderedTabs.count
        renderedTabs.insert(draggedTab, at: min(sourceIndex, renderedTabs.count))
        return renderedTabs
    }

    func renderedRowTabs(
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

    func tabs(
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

    func toggleCommandBar() {
        dismissRenamingIfNeeded()
        clearPinnedTabSelection()
        model.toggleCommandBar()
    }

    func handleSidebarTabSelection(
        _ tab: BrowserChromeModel.Tab,
        in section: BrowserSidebarTabSection
    ) {
        guard section == .spacePinned else {
            clearPinnedTabSelection()
            model.selectTab(id: tab.id)
            return
        }

        let modifiers = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if modifiers.contains(.shift) {
            selectPinnedTabRange(endingAt: tab.id)
            return
        }

        if modifiers.contains(.command) {
            togglePinnedTabSelection(tab.id)
            return
        }

        clearPinnedTabSelection()
        model.selectTab(id: tab.id)
    }

    func updateRevealedPinnedFolderTabs(for snapshot: BrowserSidebarSnapshot) {
        if let selectedTab = snapshot.selectedTab, let folderID = selectedTab.pinnedFolderID {
            revealedPinnedFolderTabIDsByFolderID[folderID, default: []].insert(selectedTab.id)
        }

        var updatedRevealedTabIDsByFolderID = [String: Set<String>]()
        for (folderID, tabIDs) in revealedPinnedFolderTabIDsByFolderID {
            guard let folder = snapshot.pinnedTabFolder(withID: folderID) else {
                continue
            }

            guard !folder.isExpanded || snapshot.selectedTab?.pinnedFolderID == folderID else {
                continue
            }

            let validTabIDs = tabIDs.filter { tabID in
                guard let tab = snapshot.tab(withID: tabID) else {
                    return false
                }

                return tab.pinnedFolderID == folderID
            }
            if !validTabIDs.isEmpty {
                updatedRevealedTabIDsByFolderID[folderID] = validTabIDs
            }
        }
        revealedPinnedFolderTabIDsByFolderID = updatedRevealedTabIDsByFolderID
    }

    func togglePinnedTabSelection(_ tabID: String) {
        if selectedPinnedTabIDs.contains(tabID) {
            selectedPinnedTabIDs.remove(tabID)
        } else {
            selectedPinnedTabIDs.insert(tabID)
            pinnedTabSelectionAnchorID = pinnedTabSelectionAnchorID ?? tabID
        }

        if selectedPinnedTabIDs.isEmpty {
            pinnedTabSelectionAnchorID = nil
        }
    }

    func selectPinnedTabRange(endingAt tabID: String) {
        let pinnedTabIDs = snapshot.spacePinnedTabs.map(\.id)
        guard let endIndex = pinnedTabIDs.firstIndex(of: tabID) else {
            return
        }

        let anchorID = pinnedTabSelectionAnchorID ?? tabID
        let startIndex = pinnedTabIDs.firstIndex(of: anchorID) ?? endIndex
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        selectedPinnedTabIDs.formUnion(pinnedTabIDs[range])
        pinnedTabSelectionAnchorID = anchorID
    }

    func clearPinnedTabSelection() {
        selectedPinnedTabIDs.removeAll()
        pinnedTabSelectionAnchorID = nil
    }

    func pinnedTabFolderCreationTabIDs(
        fromTabID tabID: String,
        in section: BrowserSidebarTabSection
    ) -> Set<String> {
        guard section != .app else {
            return []
        }
        let listTabIDs = Set((snapshot.spacePinnedTabs + snapshot.temporaryTabs).map(\.id))

        return BrowserSidebarPinnedTabFolderCreationSelection(
            clickedTabID: tabID,
            activeTabID: snapshot.selectedTabID,
            selectedTabIDs: selectedPinnedTabIDs,
            listTabIDs: listTabIDs
        )
        .tabIDs
    }

    func createPinnedTabFolder(containingTabIDs tabIDs: Set<String>) {
        guard !tabIDs.isEmpty else {
            return
        }

        dismissRenamingIfNeeded()
        clearPinnedTabSelection()
        withSidebarAnimation {
            _ = model.createPinnedTabFolder(containingTabIDs: tabIDs)
        }
    }

    func dismissRenamingIfNeeded(in window: NSWindow? = NSApp.keyWindow) {
        guard renamingTabID != nil || renamingSpaceID != nil || renamingPinnedTabFolderID != nil else {
            return
        }

        let activeRenamingTabID = renamingTabID
        let activeRenamingSpaceID = renamingSpaceID
        let activeRenamingPinnedTabFolderID = renamingPinnedTabFolderID
        window?.makeFirstResponder(nil)

        DispatchQueue.main.async { [self] in
            guard
                renamingTabID == activeRenamingTabID,
                renamingSpaceID == activeRenamingSpaceID,
                renamingPinnedTabFolderID == activeRenamingPinnedTabFolderID
            else {
                return
            }

            renamingTabID = nil
            renamingSpaceID = nil
            renamingPinnedTabFolderID = nil
        }
    }

    func resignRenamingFirstResponderIfNeeded(for event: NSEvent, in observerView: NSView) {
        guard renamingTabID != nil || renamingSpaceID != nil || renamingPinnedTabFolderID != nil,
              Date() >= renameDismissSuppressedUntil,
              let window = observerView.window,
              !isEventInsideSidebarRenameTextField(event, in: window)
        else {
            return
        }

        dismissRenamingIfNeeded(in: window)
    }

    func isEventInsideSidebarRenameTextField(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else {
            return false
        }

        func containsRenameField(_ view: NSView) -> Bool {
            if view is BrowserSidebarRenameNSTextField, !view.isHiddenOrHasHiddenAncestor,
               view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            {
                return true
            }
            return view.subviews.contains(where: containsRenameField)
        }
        return containsRenameField(contentView)
    }

    func beginRenamingTab(id tabID: String) {
        let shouldDeferRenameActivation = renamingSpaceID != nil
            || renamingPinnedTabFolderID != nil
            || (renamingTabID != nil && renamingTabID != tabID)
        suppressRenameDismissalDuringActivation()

        if renamingSpaceID != nil {
            dismissRenamingIfNeeded()
        }
        if renamingPinnedTabFolderID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingTabID, renamingTabID != tabID {
            dismissRenamingIfNeeded()
        }

        if shouldDeferRenameActivation {
            DispatchQueue.main.async { [self] in
                renamingTabID = tabID
            }
        } else {
            renamingTabID = tabID
        }
    }

    func beginRenamingSpace(id spaceID: String) {
        let shouldDeferRenameActivation = renamingTabID != nil
            || renamingPinnedTabFolderID != nil
            || (renamingSpaceID != nil && renamingSpaceID != spaceID)
        suppressRenameDismissalDuringActivation()

        if renamingTabID != nil {
            dismissRenamingIfNeeded()
        }
        if renamingPinnedTabFolderID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingSpaceID, renamingSpaceID != spaceID {
            dismissRenamingIfNeeded()
        }

        if shouldDeferRenameActivation {
            DispatchQueue.main.async { [self] in
                renamingSpaceID = spaceID
            }
        } else {
            renamingSpaceID = spaceID
        }
    }

    func beginRenamingPinnedTabFolder(id folderID: String) {
        let shouldDeferRenameActivation = renamingTabID != nil
            || renamingSpaceID != nil
            || (renamingPinnedTabFolderID != nil && renamingPinnedTabFolderID != folderID)
        suppressRenameDismissalDuringActivation()

        if renamingTabID != nil || renamingSpaceID != nil {
            dismissRenamingIfNeeded()
        }
        if let renamingPinnedTabFolderID, renamingPinnedTabFolderID != folderID {
            dismissRenamingIfNeeded()
        }

        if shouldDeferRenameActivation {
            DispatchQueue.main.async { [self] in
                renamingPinnedTabFolderID = folderID
            }
        } else {
            renamingPinnedTabFolderID = folderID
        }
    }

    func suppressRenameDismissalDuringActivation() {
        renameDismissSuppressedUntil = Date()
            .addingTimeInterval(BrowserChromeLayout.sidebarRenameActivationGraceInterval)
    }

    func updatePinnedFolderDrag(for folderID: String, value: BrowserNativeDragValue) {
        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        beginPinnedFolderDragIfNeeded(for: folderID)
        let proposal = resolvedTabDropProposal(at: value.location)
        setDropProposal(proposal)
    }

    func finishPinnedFolderDrag(for folderID: String, value: BrowserNativeDragValue) {
        guard draggedPinnedFolderID == folderID else {
            clearTabDragState()
            return
        }

        let proposal = resolvedTabDropProposal(at: value.location)
        setDropProposal(proposal)

        if let target = proposal?.target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    func beginPinnedFolderDragIfNeeded(for folderID: String) {
        guard draggedPinnedFolderID != folderID else {
            return
        }

        dismissRenamingIfNeeded()
        clearPinnedTabSelection()
        draggedPinnedFolderID = folderID
        draggedTabID = nil
        draggedTabIDs = []
        dragPreviewStore.clear()
        suppressedTabSelectionAfterDragID = nil
        tabDragSession = makeTabDragSession()
        setDropProposal(nil)
    }

    func updateTabDrag(for tabID: String, value: BrowserNativeDragValue) {
        guard suppressedTabSelectionAfterDragID != tabID else {
            clearTabDragState()
            return
        }

        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        beginTabDragIfNeeded(for: tabID, startLocation: value.startLocation, location: value.location)
        let proposal = resolvedTabDropProposal(at: value.location)
        setDropProposal(proposal)
        updateDragPreviewLocation(value.location, proposal: proposal)
    }

    func updateActiveTabDrag(for tabID: String, location: CGPoint) {
        guard draggedTabID == tabID else {
            return
        }

        guard !isSidebarResizing else {
            clearTabDragState()
            return
        }

        let proposal = resolvedTabDropProposal(at: location)
        setDropProposal(proposal)
        updateDragPreviewLocation(location, proposal: proposal)
    }

    func finishTabDrag(for tabID: String, value: BrowserNativeDragValue) {
        guard draggedTabID == tabID else {
            clearTabDragState()
            return
        }

        suppressSelectionAfterDrag(for: tabID)

        let proposal = resolvedTabDropProposal(at: value.location)
        setDropProposal(proposal)
        updateDragPreviewLocation(value.location, proposal: proposal)

        if let target = proposal?.target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    func finishActiveTabDrag(for tabID: String, location: CGPoint) {
        guard draggedTabID == tabID else {
            return
        }

        suppressSelectionAfterDrag(for: tabID)

        let proposal = resolvedTabDropProposal(at: location)
        setDropProposal(proposal)
        updateDragPreviewLocation(location, proposal: proposal)

        if let target = proposal?.target {
            moveDraggedTab(to: target)
        } else {
            clearTabDragState()
        }
    }

    func beginTabDragIfNeeded(for tabID: String, startLocation: CGPoint, location: CGPoint) {
        guard draggedTabID != tabID else {
            return
        }

        dismissRenamingIfNeeded()
        if selectedPinnedTabIDs.contains(tabID) {
            draggedTabIDs = selectedPinnedTabIDs
        } else {
            clearPinnedTabSelection()
            draggedTabIDs = [tabID]
        }
        draggedTabID = tabID
        draggedPinnedFolderID = nil
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
        tabDragSession = makeTabDragSession()
        setDropProposal(nil)
    }

    func updateDragPreviewLocation(_ location: CGPoint, proposal: BrowserSidebarTabDropProposal?) {
        dragPreviewStore.update(location: location, size: dragPreviewSize(for: proposal))
    }

    func dragPreviewSourceFrame(for tabID: String, startLocation: CGPoint) -> CGRect {
        if let frame = rawAppTabFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        if let frame = rawTabRowFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        if let frame = appTabFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        if let frame = tabRowFrames[tabID]?.frame, !frame.isEmpty {
            return frame
        }

        let fallbackWidth = max(sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)
        return CGRect(
            x: 0,
            y: startLocation.y - BrowserChromeLayout.sidebarRowHeight / 2,
            width: fallbackWidth,
            height: BrowserChromeLayout.sidebarRowHeight
        )
    }

    func dragPreviewSize(for proposal: BrowserSidebarTabDropProposal?) -> CGSize {
        if proposal?.target.section == .app {
            return dragPreviewAppTileSize(for: proposal?.target)
        }

        if let previewFrame = proposal?.previewFrame, !previewFrame.isEmpty {
            return previewFrame.size
        }

        return dragPreviewRowSize()
    }

    func dragPreviewRowSize() -> CGSize {
        if let draggedTabID, let frame = rawTabRowFrames[draggedTabID]?.frame, !frame.isEmpty {
            return frame.size
        }

        if let draggedTabID, let frame = tabRowFrames[draggedTabID]?.frame, !frame.isEmpty {
            return frame.size
        }

        return CGSize(
            width: max(sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0),
            height: BrowserChromeLayout.sidebarRowHeight
        )
    }

    func dragPreviewAppTileSize(for target: BrowserSidebarTabDropTarget?) -> CGSize {
        let proposedAppTabs = proposedAppTabs(for: target)
        let proposedFrameCount = proposedAppTabs.count
        let proposedFrames = BrowserSidebarAppTabGridLayout(
            spacing: BrowserChromeLayout.appTabGridSpacing
        )
        .frames(
            for: proposedFrameCount,
            availableWidth: max(sidebarWidth - BrowserChromeLayout.sidebarOuterPadding * 2, 0)
        )

        if
            let draggedTabID,
            let draggedIndex = proposedAppTabs.firstIndex(where: { $0.id == draggedTabID }),
            proposedFrames.indices.contains(draggedIndex)
        {
            return proposedFrames[draggedIndex].size
        }

        let sectionIndex = min(max(target?.sectionIndex ?? 0, 0), max(proposedFrameCount - 1, 0))
        if proposedFrames.indices.contains(sectionIndex) {
            return proposedFrames[sectionIndex].size
        }

        return CGSize(width: BrowserChromeLayout.sidebarRowHeight, height: BrowserChromeLayout.sidebarRowHeight)
    }

    func proposedAppTabs(for target: BrowserSidebarTabDropTarget?) -> [BrowserChromeModel.Tab] {
        guard
            let draggedTabID,
            let target,
            target.section == .app,
            let reorderedTabs = model.reorderedTabs(
                movingTabID: draggedTabID,
                toPlacement: .app,
                requestedSectionIndex: target.sectionIndex
            )
        else {
            return snapshot.appTabs
        }

        return reorderedTabs.filter { $0.placement == .app }
    }

    func resolvedTabDropProposal(at location: CGPoint) -> BrowserSidebarTabDropProposal? {
        if tabDragSession == nil {
            tabDragSession = makeTabDragSession()
        }

        guard var session = tabDragSession else {
            return nil
        }

        let proposal = session.proposal(
            for: location,
            canMoveToTarget: canMoveDraggedSidebarItem(to:)
        )
        tabDragSession = session
        return proposal
    }

    func makeTabDragSession() -> BrowserSidebarTabDragSession {
        BrowserSidebarTabDragSession(
            layout: BrowserSidebarTabDropLayout(
                rowFrames: BrowserSidebarTabFrameSynchronizer.sortedRowFrameList(tabRowFrames),
                emptySectionFrames: emptySectionFrames,
                pinnedFolderFrames: pinnedFolderRowFrames,
                spaceHeaderFrames: spaceHeaderFrames,
                appTabFrames: model.supportsAppTabs
                    ? BrowserSidebarAppTabFrameSynchronizer.sortedFrameList(appTabFrames)
                    : [],
                appTabContainerFrame: model.supportsAppTabs ? appTabsContainerFrame : nil,
                horizontalInset: 6,
                thickness: BrowserChromeLayout.sidebarDropIndicatorThickness,
                verticalSnapDistance: BrowserChromeLayout.sidebarTabDropVerticalSnapDistance,
                horizontalTolerance: BrowserChromeLayout.sidebarTabDropHorizontalTolerance
            ),
            hysteresisDistance: BrowserChromeLayout.sidebarTabDropHysteresisDistance
        )
    }

    func setTabRowFrames(
        _ frames: [String: BrowserSidebarTabRowFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawTabRowFrames = frames
        updateSynchronizedTabFrames(for: snapshot)
    }

    func updateSynchronizedTabFrames(for snapshot: BrowserSidebarSnapshot) {
        var synchronizedFrames = [String: BrowserSidebarTabRowFrame]()
        var synchronizedDropFrames = [BrowserSidebarTabRowFrame]()

        for space in snapshot.spaces {
            let pinnedRows = snapshot.isPinnedSectionCollapsed(in: space.id)
                ? []
                : snapshot.visiblePinnedRows(
                    in: space.id,
                    revealedTabIDsByFolderID: revealedPinnedFolderTabIDsByFolderID
                )
            let pinnedTabRows = pinnedRows.compactMap { row -> BrowserSidebarPinnedTabRow? in
                if case .tab(let tabRow) = row {
                    return tabRow
                }
                return nil
            }
            let spacePinnedTabIDs = pinnedTabRows.map(\.tab.id)
            let spacePinnedSectionIndices = Dictionary(uniqueKeysWithValues: pinnedTabRows.map {
                ($0.tab.id, $0.sectionIndex)
            })
            let temporaryTabIDs = snapshot.temporaryTabs(in: space.id).map(\.id)

            synchronizedFrames.merge(
                BrowserSidebarTabFrameSynchronizer.synchronizedRowFrames(
                    rawTabRowFrames,
                    spacePinnedTabIDs: spacePinnedTabIDs,
                    temporaryTabIDs: temporaryTabIDs,
                    spaceID: space.id,
                    spacePinnedSectionIndices: spacePinnedSectionIndices
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
                    spaceID: space.id,
                    spacePinnedSectionIndices: spacePinnedSectionIndices
                )
            )
        }

        tabRowFrames = synchronizedFrames
        tabDropRowFrameList = synchronizedDropFrames
    }

    func setAppTabFrames(
        _ frames: [String: BrowserSidebarAppTabFrame],
        for snapshot: BrowserSidebarSnapshot
    ) {
        rawAppTabFrames = frames
        updateSynchronizedAppTabFrames(for: snapshot)
    }

    func setAppTabsContainerFrame(
        _ frame: CGRect?,
        for snapshot: BrowserSidebarSnapshot
    ) {
        appTabsContainerFrame = frame
        updateSynchronizedAppTabFrames(for: snapshot)
    }

    func updateSynchronizedAppTabFrames(for snapshot: BrowserSidebarSnapshot) {
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

    func setEmptySectionFrames(
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

    func isTopChromeDividerVisible(forSpaceID spaceID: String) -> Bool {
        topChromeDividerVisibilityBySpaceID[spaceID] ?? false
    }

    func isBottomChromeDividerVisible(in snapshot: BrowserSidebarSnapshot) -> Bool {
        guard let selectedSpaceID = snapshot.selectedSpaceID else {
            return false
        }

        return bottomChromeDividerVisibilityBySpaceID[selectedSpaceID] ?? false
    }

    func updateTopChromeDividerVisibility(_ shouldShow: Bool, forSpaceID spaceID: String) {
        guard topChromeDividerVisibilityBySpaceID[spaceID, default: false] != shouldShow else {
            return
        }

        withSidebarAnimation {
            topChromeDividerVisibilityBySpaceID[spaceID] = shouldShow
        }
    }

    func updateBottomChromeDividerVisibility(_ shouldShow: Bool, forSpaceID spaceID: String) {
        guard bottomChromeDividerVisibilityBySpaceID[spaceID, default: false] != shouldShow else {
            return
        }

        withSidebarAnimation {
            bottomChromeDividerVisibilityBySpaceID[spaceID] = shouldShow
        }
    }

    func setDropProposal(_ proposal: BrowserSidebarTabDropProposal?) {
        guard dropProposal != proposal else {
            return
        }

        let previousTarget = dropProposal?.target
        withSidebarAnimation {
            dropProposal = proposal
        }

        if let target = proposal?.target, target != previousTarget {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func suppressSelectionAfterDrag(for tabID: String) {
        suppressedTabSelectionAfterDragID = tabID

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            guard suppressedTabSelectionAfterDragID == tabID else {
                return
            }

            suppressedTabSelectionAfterDragID = nil
        }
    }

    func canMoveDraggedSidebarItem(to target: BrowserSidebarTabDropTarget) -> Bool {
        if let draggedPinnedFolderID {
            guard target.section == .spacePinned else {
                return false
            }

            return model.canMovePinnedTabFolder(
                withID: draggedPinnedFolderID,
                toRootSectionIndex: target.sectionIndex,
                targetSpaceID: target.spaceID,
                targetParentFolderID: target.pinnedFolderID
            )
        }

        guard let draggedTabID else {
            return false
        }

        if draggedTabIDs.count > 1 {
            return model.canMoveTabs(
                withIDs: draggedTabIDs,
                toPlacement: target.section.placement,
                atSectionIndex: target.sectionIndex,
                targetSpaceID: target.spaceID,
                targetPinnedFolderID: target.pinnedFolderID
            )
        }

        return model.canMoveTab(
            withID: draggedTabID,
            toPlacement: target.section.placement,
            atSectionIndex: target.sectionIndex,
            targetSpaceID: target.spaceID,
            targetPinnedFolderID: target.pinnedFolderID
        )
    }

    func moveDraggedTab(to target: BrowserSidebarTabDropTarget) {
        if let draggedPinnedFolderID {
            dismissRenamingIfNeeded()
            clearTabDragState()

            withSidebarAnimation {
                model.movePinnedTabFolder(
                    withID: draggedPinnedFolderID,
                    toRootSectionIndex: target.sectionIndex,
                    targetSpaceID: target.spaceID,
                    targetParentFolderID: target.pinnedFolderID
                )
            }
            return
        }

        guard let draggedTabID else {
            return
        }

        let draggedTabIDs = draggedTabIDs
        dismissRenamingIfNeeded()
        clearTabDragState()

        withSidebarAnimation {
            if draggedTabIDs.count > 1 {
                model.moveTabs(
                    withIDs: draggedTabIDs,
                    toPlacement: target.section.placement,
                    atSectionIndex: target.sectionIndex,
                    targetSpaceID: target.spaceID,
                    targetPinnedFolderID: target.pinnedFolderID
                )
            } else {
                model.moveTab(
                    withID: draggedTabID,
                    toPlacement: target.section.placement,
                    atSectionIndex: target.sectionIndex,
                    targetSpaceID: target.spaceID,
                    targetPinnedFolderID: target.pinnedFolderID
                )
            }
        }
    }

    func clearTabDragState() {
        let hadTabDragState = draggedTabID != nil
            || !draggedTabIDs.isEmpty
            || draggedPinnedFolderID != nil
            || dropProposal != nil
            || tabDragSession != nil
            || dragPreviewStore.preview != nil
        draggedTabID = nil
        draggedTabIDs = []
        draggedPinnedFolderID = nil
        dropProposal = nil
        tabDragSession = nil
        dragPreviewStore.clear()

        if hadTabDragState {
            tabRowInteractionResetID += 1
        }
    }

    func withoutSidebarDragAnimation(_ updates: () -> Void) {
        updates()
        invalidate()
    }

    // MARK: Private

    private var previewObservation: AnyCancellable?
    private var updateScheduled = false
    private var shouldAnimate = false
}
