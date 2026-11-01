// BrowserNativeSidebarState.swift

import AppKit
import QuartzCore

// MARK: - BrowserNativeSidebarState

/// Selection, editing and space paging stay separate from the owned drag session.
@MainActor final class BrowserNativeSidebarState {
    private static let spacePagerScrollGain: CGFloat = 0.5
    private static let spacePagerQuickSwipeDuration = 0.5

    // MARK: Internal

    let model: BrowserChromeModel
    private(set) var snapshot: BrowserSidebarSnapshot
    var sidebarWidth: CGFloat
    var isSidebarResizing = false
    var onChange: (Bool) -> Void = { _ in }
    let drag: BrowserSidebarDragState
    var selectedSidebarTabIDs = Set<String>() { didSet { invalidate() } }
    var sidebarTabSelectionAnchorID: String?
    var spacePagerRawDragTranslation: CGFloat = 0
    /// How the Space pager moves next: a slide, or settling after a swipe.
    private(set) var rowMoveCurve = BrowserNativeAnimation.Curve.rowList
    var spacePagerCurve = BrowserNativeAnimation.Curve.spaceSelect
    /// The Space the pager is already sliding to, before the snapshot says so.
    var pagerTargetSpaceID: String?
    var renameDismissSuppressedUntil = Date.distantPast
    var isClearButtonHovered = false { didSet { invalidate() } }
    var activeTemporaryTabClearConfirmationTabID: String? { didSet { invalidate() } }
    var isSidebarHovered = false { didSet { invalidate() } }
    var renamingSpaceID: String? { didSet { invalidate() } }
    var renamingTabID: String? { didSet { invalidate() } }
    var renamingPinnedTabFolderID: String? { didSet { invalidate() } }
    var revealedPinnedFolderTabIDsByFolderID = [String: Set<String>]() {
        didSet {
            invalidate()
            model.sidebarRevealedPinnedTabIDsByFolderID = revealedPinnedFolderTabIDsByFolderID
        }
    }

    var tabRowInteractionResetID = 0 { didSet { invalidate() } }
    var topChromeDividerVisibilityBySpaceID = [String: Bool]() { didSet { invalidate() } }
    var bottomChromeDividerVisibilityBySpaceID = [String: Bool]() { didSet { invalidate() } }
    var isSpacePagerDragging = false {
        didSet {
            BrowserNativeTooltipPresenter.shared.isSuppressed = isSpacePagerDragging
            invalidate()
        }
    }

    var spacePagerDragTranslation: CGFloat = 0 { didSet { invalidate() } }

    private var spacePagerScrollStart: CFTimeInterval = 0
    private var spacePagerLastScroll: CFTimeInterval = 0
    private var spacePagerScrollVelocity: CGFloat = 0

    // MARK: Private

    private var updateScheduled = false
    private var shouldAnimate = false

    var draggedTabID: String? {
        if case .tab(let id) = drag.payload?.primary {
            id
        } else {
            nil
        }
    }

    var draggedPinnedFolderID: String? { drag.hiddenFolderID }
    var draggedTabIDs: Set<String> { drag.hiddenTabIDs }

    var isDraggingSidebarItem: Bool { drag.isDragging }

    var hasSpacePagerReleaseVelocity: Bool { spacePagerScrollVelocity != 0 }

    private var visibleSidebarTabIDs: [String] {
        guard let spaceID = snapshot.selectedSpaceID else { return [] }
        let collapsed = model.supportsSpaces && snapshot.isPinnedSectionCollapsed(in: spaceID)
        let pinnedIDs: [String] = collapsed
            ? []
            : snapshot.visiblePinnedRows(
                in: spaceID,
                revealedTabIDsByFolderID: revealedPinnedFolderTabIDsByFolderID,
            )
            .compactMap { row in
                if case .tab(let value) = row {
                    return value.tab.id
                }
                return nil
            }
        return pinnedIDs + snapshot.temporaryTabs.map(\.id)
    }

    init(model: BrowserChromeModel, snapshot: BrowserSidebarSnapshot, sidebarWidth: CGFloat) {
        self.model = model
        self.snapshot = snapshot
        self.sidebarWidth = sidebarWidth
        self.drag = BrowserSidebarDragState(model: model)
        drag.onWillCommitDrop = { [weak self] in self?.animateRows(with: .rowMove) }
        updateRevealedPinnedFolderTabs(for: snapshot)
    }

    /// Uses this curve for row moves for the next moment, for changes with a pace of
    /// their own.
    func animateRows(with curve: BrowserNativeAnimation.Curve) {
        rowMoveCurve = curve
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rowMoveCurve = .rowList
        }
    }

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
            if drag.phase == .settling {
                clearTabDragState()
            }
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
        drag.modelDidChange()
        let listTabIDs = Set((snapshot.spacePinnedTabs + snapshot.temporaryTabs).map(\.id))
        selectedSidebarTabIDs.formIntersection(listTabIDs)
        if let anchor = sidebarTabSelectionAnchorID, !listTabIDs.contains(anchor) {
            sidebarTabSelectionAnchorID = nil
        }
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
        drag.proposal?.feedback == .folder(folderID)
    }

    func isSpaceHeaderDropTarget(spaceID: String) -> Bool {
        drag.proposal?.feedback == .space(spaceID)
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
        pageWidth: CGFloat,
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
                pageWidth: pageWidth,
            )
        }
    }

    func finishSpacePagerDrag(
        _ value: BrowserNativeDragValue,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat,
    ) {
        guard isSpacePagerDragging else {
            resetSpacePagerDrag()
            return
        }

        let targetSpaceID = targetSpaceID(for: value, in: snapshot, pageWidth: pageWidth)
        spacePagerCurve = .spaceSelect
        withSidebarAnimation {
            isSpacePagerDragging = false
            spacePagerRawDragTranslation = 0
            spacePagerDragTranslation = 0
            if let targetSpaceID {
                model.selectSpace(id: targetSpaceID)
            }
        }
    }

    /// The velocity a finished swipe hands to the slide, in points per second. Once.
    func takeSpacePagerReleaseVelocity() -> CGFloat {
        defer { spacePagerScrollVelocity = 0 }
        return spacePagerScrollVelocity
    }

    func updateSpacePagerScroll(
        by delta: CGFloat,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat,
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

        let now = CACurrentMediaTime()
        if !isSpacePagerDragging {
            dismissRenamingIfNeeded()
            isSpacePagerDragging = true
            spacePagerScrollStart = now
            spacePagerLastScroll = now
        }
        let moved = delta * Self.spacePagerScrollGain
        // Events can arrive in a burst after a busy moment, so a frame is the shortest step.
        let step = moved / max(now - spacePagerLastScroll, 1 / 60)
        spacePagerScrollVelocity = spacePagerScrollVelocity == 0 ? step : (spacePagerScrollVelocity + step) / 2
        spacePagerLastScroll = now

        spacePagerCurve = .spaceSelect
        withoutSidebarDragAnimation {
            spacePagerRawDragTranslation += moved
            spacePagerDragTranslation = constrainedSpacePagerTranslation(
                spacePagerRawDragTranslation,
                selectedIndex: selectedIndex,
                spaceCount: snapshot.spaces.count,
                pageWidth: pageWidth,
            )
        }
    }

    func finishSpacePagerScroll(
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat,
    ) {
        guard isSpacePagerDragging else {
            resetSpacePagerDrag()
            return
        }

        // A quick swipe always turns the page; a slow one has to pass the middle.
        let translation = spacePagerRawDragTranslation
        let isQuick = CACurrentMediaTime() - spacePagerScrollStart < Self.spacePagerQuickSwipeDuration
        let turnsPage = translation != 0 && (isQuick || abs(translation) >= pageWidth / 2)
        let targetSpaceID = targetSpaceID(
            forProjectedTranslation: turnsPage ? (translation < 0 ? -pageWidth : pageWidth) : 0,
            in: snapshot,
            pageWidth: pageWidth,
        )
        spacePagerCurve = .spaceSelect
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
        pageWidth: CGFloat,
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

        let overscrollLimit: CGFloat = 255
        let resistedOverflow = rubberBandDistance(
            magnitude - pageLimit,
            limit: overscrollLimit,
        )
        return direction * (pageLimit + resistedOverflow)
    }

    func targetSpaceID(
        for value: BrowserNativeDragValue,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat,
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
            pageWidth: pageWidth,
        )
    }

    func targetSpaceID(
        forProjectedTranslation projectedTranslation: CGFloat,
        in snapshot: BrowserSidebarSnapshot,
        pageWidth: CGFloat,
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

        return limit * (1 - 1 / (distance * 0.15 / limit + 1))
    }

    func renderedSnapshot(for snapshot: BrowserSidebarSnapshot) -> BrowserSidebarSnapshot {
        guard let plan = drag.projectedPlan else { return snapshot }
        return BrowserSidebarSnapshot(
            spaces: snapshot.spaces, selectedSpaceID: snapshot.selectedSpaceID, activeSpace: snapshot.activeSpace,
            isActiveSpacePinnedSectionCollapsed: snapshot.isActiveSpacePinnedSectionCollapsed,
            allTabs: snapshot.allTabs, pinnedTabFolders: snapshot.pinnedTabFolders,
            appTabs: plan.tabs.filter { $0.placement == .app }, spacePinnedTabs: snapshot.spacePinnedTabs,
            temporaryTabs: snapshot.temporaryTabs, selectedTabID: snapshot.selectedTabID,
            archivableTabIDs: snapshot.archivableTabIDs, canGoBack: snapshot.canGoBack,
            canGoForward: snapshot.canGoForward, canStopLoading: snapshot.canStopLoading, canReload: snapshot.canReload,
        )
    }

    func toggleCommandBar() {
        dismissRenamingIfNeeded()
        clearSidebarTabSelection()
        model.toggleCommandBar()
    }

    func handleSidebarTabSelection(
        _ tab: BrowserChromeModel.Tab,
        in section: BrowserSidebarTabSection,
        modifiers: NSEvent.ModifierFlags = [],
    ) {
        guard section != .app else {
            clearSidebarTabSelection()
            model.selectTab(id: tab.id)
            return
        }

        if modifiers.contains(.shift) {
            selectSidebarTabRange(endingAt: tab.id)
            return
        }

        if modifiers.contains(.command) {
            toggleSidebarTabSelection(tab.id)
            return
        }

        clearSidebarTabSelection()
        sidebarTabSelectionAnchorID = tab.id
        model.selectTab(id: tab.id)
    }

    func updateRevealedPinnedFolderTabs(for snapshot: BrowserSidebarSnapshot) {
        if let selectedTab = snapshot.selectedTab, let folderID = selectedTab.pinnedFolderID {
            revealedPinnedFolderTabIDsByFolderID[folderID, default: []].insert(selectedTab.id)
        }

        var updatedRevealedTabIDsByFolderID = [String: Set<String>]()
        for (folderID, tabIDs) in revealedPinnedFolderTabIDsByFolderID {
            guard let folder = snapshot.pinnedTabFolder(withID: folderID),
                  !folder.isExpanded || snapshot.selectedTab?.pinnedFolderID == folderID
            else {
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

    func toggleSidebarTabSelection(_ tabID: String) {
        guard visibleSidebarTabIDs.contains(tabID) else { return }
        if selectedSidebarTabIDs.contains(tabID) {
            selectedSidebarTabIDs.remove(tabID)
        } else {
            selectedSidebarTabIDs.insert(tabID)
            sidebarTabSelectionAnchorID = sidebarTabSelectionAnchorID ?? tabID
        }

        if selectedSidebarTabIDs.isEmpty {
            sidebarTabSelectionAnchorID = nil
        }
    }

    func selectSidebarTabRange(endingAt tabID: String) {
        let listTabIDs = visibleSidebarTabIDs
        guard let endIndex = listTabIDs.firstIndex(of: tabID) else {
            return
        }

        let anchorID = sidebarTabSelectionAnchorID ?? snapshot.selectedTabID ?? tabID
        let startIndex = listTabIDs.firstIndex(of: anchorID) ?? endIndex
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        selectedSidebarTabIDs.formUnion(listTabIDs[range])
        sidebarTabSelectionAnchorID = anchorID
    }

    func clearSidebarTabSelection() {
        selectedSidebarTabIDs.removeAll()
        sidebarTabSelectionAnchorID = nil
    }

    func pinnedTabFolderCreationTabIDs(
        fromTabID tabID: String,
        in section: BrowserSidebarTabSection,
    ) -> Set<String> {
        guard section != .app else {
            return []
        }
        let listTabIDs = Set((snapshot.spacePinnedTabs + snapshot.temporaryTabs).map(\.id))

        return BrowserSidebarPinnedTabFolderCreationSelection(
            clickedTabID: tabID,
            activeTabID: snapshot.selectedTabID,
            selectedTabIDs: selectedSidebarTabIDs,
            listTabIDs: listTabIDs,
        )
        .tabIDs
    }

    func createPinnedTabFolder(containingTabIDs tabIDs: Set<String>) {
        guard !tabIDs.isEmpty else {
            return
        }

        dismissRenamingIfNeeded()
        clearSidebarTabSelection()
        withSidebarAnimation {
            _ = model.createPinnedTabFolder(containingTabIDs: tabIDs)
        }
    }

    func dismissRenamingIfNeeded(in window: NSWindow? = NSApp?.keyWindow) {
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

    func clearTabDragState() {
        let hadDrag = drag.phase != .idle
        drag.complete()
        if hadDrag {
            tabRowInteractionResetID += 1
        }
    }

    func withoutSidebarDragAnimation(_ updates: () -> Void) {
        updates()
        invalidate()
    }
}

// MARK: - Folder preview

extension BrowserNativeSidebarState {
    /// Every tab in a folder and its subfolders, in sidebar order.
    func folderPreviewItems(folderID: String) -> [BrowserFolderPreviewItem] {
        guard let folder = snapshot.pinnedTabFolder(withID: folderID) else { return [] }
        let tree = BrowserSidebarTabTree(snapshot: snapshot)
        return tree.tabIDs(in: .pinned(folder.spaceID, folderID: folderID)).compactMap { id in
            snapshot.tab(withID: id).map {
                BrowserFolderPreviewItem(
                    id: $0.id,
                    title: $0.displayTitle,
                    urlString: $0.urlString,
                    faviconURL: $0.faviconURL,
                )
            }
        }
    }
}
