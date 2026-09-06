import AppKit

/// One gesture owns one payload and one semantic proposal. Pointer motion updates
/// only its presentation; it does not rebuild the sidebar or mutate the tab model.
@MainActor final class BrowserSidebarDragState {
    // MARK: Lifecycle

    init(
        model: BrowserChromeModel,
        planner: ((BrowserSidebarDragPayload, BrowserSidebarDropDestination) -> BrowserSidebarMovePlan?)? = nil
    ) {
        self.model = model
        self.planner = planner ?? { model.sidebarMovePlan(payload: $0, destination: $1) }
    }

    // MARK: Internal

    enum Phase { case idle, dragging, settling }

    private(set) var phase = Phase.idle
    private(set) var payload: BrowserSidebarDragPayload?
    private(set) var proposal: BrowserSidebarDropProposal?
    private(set) var pointer = CGPoint.zero
    private(set) var anchor = CGPoint(x: 0.5, y: 0.5)
    private(set) var sourceFrame = CGRect.zero
    private(set) var geometry: BrowserSidebarDragGeometry?
    private(set) var projectedPlan: BrowserSidebarMovePlan?
    var onPresentationChange: () -> Void = {}
    var onLayoutChange: () -> Void = {}
    var onTargetChange: () -> Void = {}

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

    func begin(
        payload: BrowserSidebarDragPayload,
        sourceFrame: CGRect,
        start: CGPoint,
        pointer: CGPoint,
        grabAnchor: CGPoint? = nil
    ) {
        self.payload = payload
        self.sourceFrame = sourceFrame
        self.pointer = pointer
        refreshSourceMetadata()
        anchor = grabAnchor ?? CGPoint(
            x: min(max((start.x - sourceFrame.minX) / max(sourceFrame.width, 1), 0), 1),
            y: min(max((start.y - sourceFrame.minY) / max(sourceFrame.height, 1), 0), 1)
        )
        phase = .dragging
        proposal = nil
        geometricProposal = nil
        projectedPlan = nil
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

    func updatePointer(_ pointer: CGPoint) {
        guard isDragging, let payload else { return }
        self.pointer = pointer
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

    @discardableResult func release(at pointer: CGPoint, cancel: Bool = false) -> Bool {
        guard isDragging, let payload else { return false }
        if !cancel {
            updatePointer(pointer)
        }
        let committed = !cancel && proposal.map {
            model.commitSidebarDrop(payload: payload, destination: $0.destination)
        } == true
        phase = .settling
        proposal = nil
        geometricProposal = nil
        projectedPlan = nil
        onPresentationChange()
        return committed
    }

    func complete() {
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

    // MARK: Private

    private var geometricProposal: BrowserSidebarDropProposal?
    private let model: BrowserChromeModel
    private let planner: (BrowserSidebarDragPayload, BrowserSidebarDropDestination) -> BrowserSidebarMovePlan?
    private var sourceContainer: BrowserSidebarDropContainer?
    private var hiddenFolders = Set<String>()

    private var plans = [BrowserSidebarDropDestination: BrowserSidebarMovePlan]()
    private var validity = [BrowserSidebarDropDestination: Bool]()

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
        destination: BrowserSidebarDropDestination
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
