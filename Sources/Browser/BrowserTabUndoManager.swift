import Foundation

/// Keeps AppKit's ordinary undo stack and responder routing. Tab operations
/// preflight outside Foundation because a page may asynchronously cancel Close.
@MainActor final class BrowserTabUndoManager: UndoManager {
    // MARK: Internal

    struct Action {
        let name: String
        let perform: @MainActor (@escaping @MainActor (Outcome) -> Void) -> Void
    }

    enum Outcome {
        case committed(inverse: Action?)
        case cancelled
    }

    /// Foundation owns this metadata and the unique target with the registration.
    /// Keeping its key internal also permits inspecting/removing a specific entry.
    static let tabActionKey = UndoManager.UserInfoKey(rawValue: "browser.tabUndo.action")

    override var canUndo: Bool {
        if isInvokingFoundation {
            return super.canUndo
        }
        guard pending == nil, groupingLevel <= 1, super.canUndo else { return false }
        return marker(on: .undo) == nil || canPerformTabAction?() != false
    }

    override var canRedo: Bool {
        if isInvokingFoundation {
            return super.canRedo
        }
        guard pending == nil, groupingLevel == 0, super.canRedo else { return false }
        return marker(on: .redo) == nil || canPerformTabAction?() != false
    }

    /// Gates tab transitions only. Native text undo continues to use Foundation.
    var canPerformTabAction: (() -> Bool)?

    var isTabTransitionPending: Bool { pending != nil }

    /// Name of the tab action Undo would perform next, or nil when the top of
    /// the stack is text editing or another transition is running.
    var undoTabActionName: String? { pending == nil ? marker(on: .undo)?.action.name : nil }

    override func undo() { perform(.undo) }
    override func redo() { perform(.redo) }

    override func undoNestedGroup() {
        // Foundation's undo() may dynamically call this override. Only direct
        // callers need the asynchronous preflight; never execute it twice.
        if isInvokingFoundation {
            super.undoNestedGroup()
        } else {
            perform(.undo)
        }
    }

    override func endUndoGrouping() {
        super.endUndoGrouping()
        flushDeferredActions()
    }

    override func removeAllActions() {
        epoch = UUID()
        pending = nil
        prepared = nil
        deferredActions.removeAll()
        super.removeAllActions()
    }

    override func removeAllActions(withTarget target: Any) {
        if let pending, (target as AnyObject) === pending.marker {
            self.pending = nil
            prepared = nil
        }
        super.removeAllActions(withTarget: target)
    }

    func registerTabAction(_ action: Action) {
        guard isUndoRegistrationEnabled else { return }
        // Do not label a native/mixed group as a tab action. Its caller still
        // owns the open group; tab registrations follow after it closes.
        guard groupingLevel == 0, !isInvokingFoundation else {
            deferredActions.append(action)
            return
        }
        beginUndoGrouping()
        installMarker(action)
        endUndoGrouping()
    }

    // MARK: Private

    private enum Direction: Equatable {
        case undo, redo
    }

    private final class Marker: NSObject {
        // MARK: Lifecycle

        init(action: Action) { self.action = action }

        // MARK: Internal

        let action: Action
    }

    private struct Pending {
        let nonce: UUID
        let epoch: UUID
        let marker: Marker
        let direction: Direction
    }

    private struct Prepared {
        let marker: Marker
        let inverse: Action?
    }

    private var epoch = UUID()
    private var pending: Pending?
    private var prepared: Prepared?
    private var isInvokingFoundation = false
    private var deferredActions = [Action]()

    private func marker(on direction: Direction) -> Marker? {
        switch direction {
        case .undo: undoActionUserInfoValue(forKey: Self.tabActionKey) as? Marker
        case .redo: redoActionUserInfoValue(forKey: Self.tabActionKey) as? Marker
        }
    }

    private func perform(_ direction: Direction) {
        guard pending == nil, !isInvokingFoundation else { return }
        // Match Foundation's top-level undo behavior; do not close somebody
        // else's nested group or move history while that group is incomplete.
        if direction == .undo, groupingLevel == 1 {
            endUndoGrouping()
        }
        guard groupingLevel == 0 else { return }
        let available = direction == .undo ? super.canUndo : super.canRedo
        guard available else { return }
        guard let marker = marker(on: direction) else {
            invokeFoundation(direction)
            return
        }
        guard canPerformTabAction?() != false else { return }
        let request = Pending(nonce: UUID(), epoch: epoch, marker: marker, direction: direction)
        pending = request
        marker.action.perform { [weak self] outcome in
            self?.finish(request, outcome: outcome)
        }
    }

    private func finish(_ request: Pending, outcome: Outcome) {
        guard epoch == request.epoch, pending?.nonce == request.nonce else { return }
        switch outcome {
        case .cancelled:
            pending = nil
        case .committed(let inverse):
            if groupingLevel == 0, marker(on: request.direction) === request.marker {
                prepared = Prepared(marker: request.marker, inverse: inverse)
                invokeFoundation(request.direction)
                prepared = nil
                pending = nil
            } else {
                // New native/tab edits may replace the original top or clear
                // its redo branch. Remove only this entry, never those edits.
                super.removeAllActions(withTarget: request.marker)
                pending = nil
                if request.direction == .redo, let inverse {
                    // Redo's business effect committed after the newer edit.
                    // Its inverse is therefore the newest Undo, not a revived
                    // old redo branch. Interrupted Undo creates no redo branch.
                    registerTabAction(inverse)
                }
            }
        }
        flushDeferredActions()
    }

    private func invokeFoundation(_ direction: Direction) {
        isInvokingFoundation = true
        switch direction {
        case .undo: super.undo()
        case .redo: super.redo()
        }
        isInvokingFoundation = false
        flushDeferredActions()
    }

    private func installMarker(_ action: Action) {
        let marker = Marker(action: action)
        // The block intentionally retains its unique marker target. The marker
        // does not retain this manager; it expires with its Foundation entry.
        registerUndo(withTarget: marker) { [weak self, marker] _ in
            guard let self, let prepared, prepared.marker === marker else { return }
            if let inverse = prepared.inverse {
                installMarker(inverse)
            }
        }
        setActionName(action.name)
        setActionUserInfoValue(marker, forKey: Self.tabActionKey)
    }

    private func flushDeferredActions() {
        guard groupingLevel == 0, !isInvokingFoundation, !deferredActions.isEmpty else { return }
        let actions = deferredActions
        deferredActions.removeAll()
        for action in actions {
            registerTabAction(action)
        }
    }
}
