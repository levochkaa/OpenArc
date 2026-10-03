import UIKit

/// App-local drag identity and the shared barrier for every participating sidebar.
/// Participants are weak: a disconnected source cannot retain an entire window.
@MainActor final class BrowserMobileSidebarDragSession {
    // MARK: Lifecycle

    init(
        owner: BrowserMobileTabsViewController, document: BrowserMobileProfileDocument,
        spaceID: String?, source: BrowserMobileSidebarDrop.Source, sourceSessionID: ObjectIdentifier
    ) {
        self.owner = owner
        self.document = document
        self.spaceID = spaceID
        self.source = source
        self.sourceSessionID = sourceSessionID
        self.participants = [Participant(owner)]
    }

    // MARK: Internal

    weak var owner: BrowserMobileTabsViewController?
    weak var document: BrowserMobileProfileDocument?
    let spaceID: String?
    let source: BrowserMobileSidebarDrop.Source
    let sourceSessionID: ObjectIdentifier
    var dragItemIDs = Set<ObjectIdentifier>()
    private(set) var isCancelled = false
    private(set) var isCommitted = false
    private(set) var animationBatchID: UUID?
    private(set) var pendingDropAnimations = Set<ObjectIdentifier>()

    var isHoldingRows: Bool {
        isCommitting || !pendingDropAnimations.isEmpty
            || participants.contains { $0.controller?.sidebarDragHasNativeHold == true }
    }

    func register(_ controller: BrowserMobileTabsViewController) {
        participants.removeAll { $0.controller == nil }
        if !participants.contains(where: { $0.controller === controller }) {
            participants.append(Participant(controller))
        }
    }

    func matches(_ items: [UIDragItem]) -> Bool {
        items.count == source.items.count && !items.isEmpty
            && Set(items.map(ObjectIdentifier.init)) == dragItemIDs
            && dragItemIDs.count == items.count
            && items.allSatisfy { $0.localObject as? BrowserMobileSidebarDragSession === self }
    }

    func commit(_ action: () -> Bool) -> UUID? {
        guard !isCancelled, !isCommitted,
              !participants.contains(where: { $0.controller?.sidebarDragHasHoverProjection == true })
        else { return nil }
        // Freeze both observers and claim the once-only commit before publishing.
        isCommitted = true
        isCommitting = true
        let batchID = UUID()
        animationBatchID = batchID
        pendingDropAnimations = dragItemIDs
        let moved = action()
        isCommitting = false
        if !moved {
            isCancelled = true
            animationBatchID = nil
            pendingDropAnimations.removeAll()
        }
        notifyParticipants()
        return moved ? batchID : nil
    }

    func invalidate() {
        isCancelled = true
        notifyParticipants()
    }

    func finishAnimation(itemID: ObjectIdentifier, batchID: UUID) {
        guard animationBatchID == batchID, pendingDropAnimations.remove(itemID) != nil else { return }
        if pendingDropAnimations.isEmpty {
            animationBatchID = nil
        }
        notifyParticipants()
    }

    func concludeAnimations(batchID: UUID) {
        guard animationBatchID == batchID else { return }
        pendingDropAnimations.removeAll()
        animationBatchID = nil
        notifyParticipants()
    }

    func notifyParticipants() {
        let controllers = participants.compactMap(\.controller)
        for controller in controllers {
            controller.sidebarDragSessionDidChange(self)
        }
    }

    // MARK: Private

    private final class Participant {
        // MARK: Lifecycle

        init(_ controller: BrowserMobileTabsViewController) { self.controller = controller }

        // MARK: Internal

        weak var controller: BrowserMobileTabsViewController?
    }

    private var participants: [Participant]
    private var isCommitting = false
}
