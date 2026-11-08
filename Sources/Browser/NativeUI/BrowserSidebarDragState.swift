// BrowserSidebarDragState.swift

import AppKit

/// One gesture owns one payload and one semantic proposal. Pointer motion updates
/// only its presentation; it does not rebuild the sidebar or mutate the tab model.
@MainActor final class BrowserSidebarDragState {
    // MARK: Internal

    enum Phase { case idle, dragging, settling }

    /// A tab row that the dragged tab will join as a Split View, on the row's
    /// leading or trailing half.
    struct SplitDropTarget: Equatable {
        enum Side { case leading, trailing }

        let tabID: String
        let side: Side
    }

    /// A drop on the page beside the sidebar: the dragged tab opens in a Split
    /// View next to the page or pane under the pointer, or, in the middle of a
    /// shown split's pane, takes that pane's place.
    struct PageSplitDropTarget: Equatable {
        let anchorTabID: String
        var insertion = BrowserChromeModel.SplitInsertion.end
        var orientation = BrowserTabSplitOrientation.horizontal
        var replacesAnchor = false
    }

    /// A dragged tab combines with the tab row it rests on into a Split View
    /// after a short pause; the pause keeps ordinary reorders unaffected.
    static let splitDropDelay: TimeInterval = 0.5

    /// The middle of a row, away from the insertion edges, offers the split.
    static let splitDropBandFraction: CGFloat = 0.5

    /// A drag resting on a Space's dock icon switches to that Space. The pause
    /// keeps a drag passing over the dock from switching Spaces.
    static let dockSpringDelay: TimeInterval = 0.1

    private(set) var phase = Phase.idle
    private(set) var payload: BrowserSidebarDragPayload?
    private(set) var proposal: BrowserSidebarDropProposal?
    private(set) var pointer = CGPoint.zero
    private(set) var anchor = CGPoint(x: 0.5, y: 0.5)
    private(set) var sourceFrame = CGRect.zero
    private(set) var geometry: BrowserSidebarDragGeometry?
    private(set) var projectedPlan: BrowserSidebarMovePlan?
    private(set) var splitTarget: SplitDropTarget?
    private(set) var pageSplitTarget: PageSplitDropTarget?
    /// The Space whose dock icon is under the pointer. A drop there moves the
    /// items to the top of their section in that Space.
    private(set) var dockSpaceID: String?
    /// Finds the page drop for a window point and the dragged tab and shows its
    /// preview; a nil point clears the preview. Set by the window root.
    var pageSplitDropResolver: ((CGPoint?, String) -> PageSplitDropTarget?)?
    var onPresentationChange: () -> Void = {}
    var onLayoutChange: () -> Void = {}
    var onTargetChange: () -> Void = {}
    var onWillCommitDrop: () -> Void = {}

    // MARK: Private

    private var geometricProposal: BrowserSidebarDropProposal?
    private let model: BrowserChromeModel
    private let planner: (BrowserSidebarDragPayload, BrowserSidebarDropDestination) -> BrowserSidebarMovePlan?
    private var sourceContainer: BrowserSidebarDropContainer?
    private var hiddenFolders = Set<String>()

    private var plans = [BrowserSidebarDropDestination: BrowserSidebarMovePlan]()
    private var validity = [BrowserSidebarDropDestination: Bool]()
    private var splitCandidateTabID: String?
    private var splitCandidateSince = Date.distantFuture
    private var splitDelayWork: DispatchWorkItem?
    private var dockSpringWork: DispatchWorkItem?

    var isDragging: Bool { phase == .dragging }
    var hiddenTabIDs: Set<String> { payload?.tabIDs ?? [] }
    var hiddenFolderID: String? {
        if case .folder(let id) = payload?.primary {
            id
        } else {
            nil
        }
    }

    var isAppPreview: Bool {
        guard let payload, case .tab = payload.primary else { return false }
        return projectedPlan != nil || (sourceContainer?.section == .app
            && geometry?.appFrame?.contains(pointer) == true)
    }

    var hiddenFolderIDs: Set<String> { hiddenFolders }

    var previewSize: CGSize {
        if isAppPreview, let geometricProposal {
            return geometricProposal.previewSize
        }
        if let proposal {
            return proposal.previewSize
        }
        guard let payload else { return sourceFrame.size }
        if let geometricProposal,
           geometricProposal.destination.container == sourceContainer
        {
            return geometricProposal.previewSize
        }
        if case .folder = payload.primary {
            return sourceFrame.size
        }
        return CGSize(width: geometry?.rowWidth ?? sourceFrame.width, height: BrowserChromeLayout.sidebarRowHeight)
    }

    init(
        model: BrowserChromeModel,
        planner: ((BrowserSidebarDragPayload, BrowserSidebarDropDestination) -> BrowserSidebarMovePlan?)? = nil,
    ) {
        self.model = model
        self.planner = planner ?? { model.sidebarMovePlan(payload: $0, destination: $1) }
    }

    func begin(
        payload: BrowserSidebarDragPayload,
        sourceFrame: CGRect,
        start: CGPoint,
        pointer: CGPoint,
        grabAnchor: CGPoint? = nil,
    ) {
        self.payload = payload
        self.sourceFrame = sourceFrame
        self.pointer = pointer
        refreshSourceMetadata()
        anchor = grabAnchor ?? CGPoint(
            x: min(max((start.x - sourceFrame.minX) / max(sourceFrame.width, 1), 0), 1),
            y: min(max((start.y - sourceFrame.minY) / max(sourceFrame.height, 1), 0), 1),
        )
        phase = .dragging
        proposal = nil
        geometricProposal = nil
        projectedPlan = nil
        resetSplitDrop()
        plans.removeAll()
        validity.removeAll()
    }

    func updateGeometry(_ geometry: BrowserSidebarDragGeometry) {
        self.geometry = geometry
        if isDragging {
            updatePointer(pointer)
        }
    }

    func modelDidChange() {
        refreshSourceMetadata()
        plans.removeAll()
        validity.removeAll()
        if let payload,
           !payload.tabIDs.isSubset(of: Set(model.sidebarSnapshot.allTabs.map(\.id)))
        {
            complete()
        }
    }

    /// Follows the pointer over the dock: resting on another Space's icon
    /// switches to that Space.
    func updateDockTarget(_ spaceID: String?) {
        guard isDragging, spaceID != dockSpaceID else { return }
        dockSpaceID = spaceID
        dockSpringWork?.cancel()
        dockSpringWork = nil
        if spaceID != nil {
            resetSplitDrop()
        }
        if let spaceID, spaceID != model.selectedSpaceID {
            let work = DispatchWorkItem { [weak self] in
                guard let self, isDragging, dockSpaceID == spaceID else { return }
                model.selectSpace(id: spaceID)
            }
            dockSpringWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dockSpringDelay, execute: work)
        }
        updatePointer(pointer)
    }

    func updatePointer(_ pointer: CGPoint) {
        guard isDragging, let payload else { return }
        self.pointer = pointer
        if dockSpaceID != nil || updateSplitDrop(payload: payload) {
            let hadProposal = proposal != nil || projectedPlan != nil
            proposal = nil
            geometricProposal = nil
            projectedPlan = nil
            if hadProposal {
                onLayoutChange()
            }
            onPresentationChange()
            return
        }
        let proposed = geometry?.proposal(at: pointer, previous: proposal)
        geometricProposal = proposed
        let resolution = proposed.map { resolve(payload: payload, destination: $0.destination) }
        let plan = resolution?.plan
        let next = resolution?.valid == true ? proposed : nil
        let old = proposal
        let oldProjection = projectedPlan?.destination
        proposal = next
        projectedPlan = next?.destination.container.section == .app ? plan : nil
        if old?.destination != next?.destination, next != nil {
            onTargetChange()
        }
        if oldProjection != projectedPlan?.destination {
            onLayoutChange()
        }
        onPresentationChange()
    }

    /// Follows the pointer over the page. Only a single tab outside every
    /// sidebar target can split the page.
    func updatePageDrop(atWindowPoint point: CGPoint) {
        guard isDragging, let payload, payload.tabIDs.count == 1, case .tab(let id) = payload.primary,
              proposal == nil, splitTarget == nil, dockSpaceID == nil
        else {
            clearPageDrop()
            return
        }
        let target = pageSplitDropResolver?(point, id)
        guard target != pageSplitTarget else { return }
        pageSplitTarget = target
        onPresentationChange()
    }

    @discardableResult func release(at pointer: CGPoint, cancel: Bool = false) -> Bool {
        guard isDragging, let payload else { return false }
        if !cancel {
            updatePointer(pointer)
        }
        let committed: Bool =
            if !cancel, let dockSpaceID {
                model.moveSidebarItems(payload, toTopOfSpace: dockSpaceID)
            } else if !cancel, let target = splitTarget, case .tab(let id) = payload.primary {
                model.openInSplitView(
                    tabID: id,
                    anchorTabID: target.tabID,
                    insertion: target.side == .leading ? .before : .after,
                )
            } else if !cancel, let target = pageSplitTarget, target.replacesAnchor,
                      case .tab(let id) = payload.primary
            {
                model.replaceSplitPane(anchorTabID: target.anchorTabID, with: id)
            } else if !cancel, let target = pageSplitTarget, case .tab(let id) = payload.primary {
                model.openInSplitView(
                    tabID: id,
                    anchorTabID: target.anchorTabID,
                    insertion: target.insertion,
                    orientation: target.orientation,
                )
            } else {
                !cancel && proposal.map { proposal in
                    onWillCommitDrop()
                    return model.withArrangementUndo(BrowserStrings.undoMoveAction) {
                        model.commitSidebarDrop(payload: payload, destination: proposal.destination)
                    }
                } == true
            }
        resetSplitDrop()
        resetDockTarget()
        clearPageDrop()
        phase = .settling
        proposal = nil
        geometricProposal = nil
        projectedPlan = nil
        onPresentationChange()
        return committed
    }

    func complete() {
        resetSplitDrop()
        resetDockTarget()
        clearPageDrop()
        phase = .idle
        payload = nil
        sourceContainer = nil
        hiddenFolders.removeAll()
        proposal = nil
        geometricProposal = nil
        projectedPlan = nil
        geometry = nil
        plans.removeAll()
        validity.removeAll()
        onPresentationChange()
    }

    private func clearPageDrop() {
        let hadTarget = pageSplitTarget != nil
        pageSplitTarget = nil
        _ = pageSplitDropResolver?(nil, "")
        if hadTarget {
            onPresentationChange()
        }
    }

    private func resetDockTarget() {
        dockSpringWork?.cancel()
        dockSpringWork = nil
        dockSpaceID = nil
    }

    private func resetSplitDrop() {
        splitDelayWork?.cancel()
        splitDelayWork = nil
        splitCandidateTabID = nil
        splitTarget = nil
    }

    /// True while the pointer rests on a split target. Moving to another row
    /// restarts the pause; moving between halves of the same row only flips
    /// the side.
    private func updateSplitDrop(payload: BrowserSidebarDragPayload) -> Bool {
        guard let candidate = splitCandidate(payload: payload) else {
            resetSplitDrop()
            return false
        }
        if candidate.tabID != splitCandidateTabID {
            resetSplitDrop()
            splitCandidateTabID = candidate.tabID
            splitCandidateSince = Date()
            let work = DispatchWorkItem { [weak self] in
                guard let self, isDragging else { return }
                updatePointer(pointer)
            }
            splitDelayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.splitDropDelay, execute: work)
            return false
        }
        guard Date().timeIntervalSince(splitCandidateSince) >= Self.splitDropDelay - 0.01 else { return false }
        splitTarget = candidate
        return true
    }

    private func splitCandidate(payload: BrowserSidebarDragPayload) -> SplitDropTarget? {
        guard payload.tabIDs.count == 1, case .tab(let draggedID) = payload.primary,
              let row = geometry?.rows.first(where: { $0.frame.contains(pointer) }),
              case .tab(let targetID) = row.item, targetID != draggedID, row.container.section != .app
        else { return nil }
        let band = row.frame.height * (1 - Self.splitDropBandFraction) / 2
        guard pointer.y >= row.frame.minY + band, pointer.y <= row.frame.maxY - band,
              model.canOpenInSplitView(tabID: draggedID, anchorTabID: targetID)
        else { return nil }
        return SplitDropTarget(tabID: targetID, side: pointer.x < row.frame.midX ? .leading : .trailing)
    }

    private func refreshSourceMetadata() {
        guard let payload else { sourceContainer = nil
            hiddenFolders = []
            return
        }
        let tree = BrowserSidebarTabTree(snapshot: model.sidebarSnapshot)
        sourceContainer = tree.container(of: payload.primary)
        hiddenFolders =
            if case .folder(let id) = payload.primary {
                tree.descendantFolderIDs(including: id)
            } else {
                []
            }
    }

    private func resolve(
        payload: BrowserSidebarDragPayload,
        destination: BrowserSidebarDropDestination,
    ) -> (valid: Bool, plan: BrowserSidebarMovePlan?) {
        if let valid = validity[destination] {
            return (valid, plans[destination])
        }
        guard let plan = planner(payload, destination) else {
            validity[destination] = false
            return (false, nil)
        }
        validity[destination] = true
        // Only the app-grid needs a projected order. Keep list validation O(slots)
        // memory rather than retaining a full copy of all tabs for every gap.
        if destination.container.section == .app {
            plans[destination] = plan
        }
        return (true, plan)
    }
}
