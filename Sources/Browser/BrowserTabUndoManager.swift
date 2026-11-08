// BrowserTabUndoManager.swift

import Foundation

/// Keeps AppKit's ordinary undo stack and responder routing. Tab operations
/// preflight outside Foundation because a page may asynchronously cancel Close.
@MainActor final class BrowserTabUndoManager: UndoManager {
    // MARK: Internal

    struct Action {
        let name: String
        let perform: @MainActor (@escaping @MainActor (Outcome) -> Void) -> Void
        /// Actions of one command, such as Clear, that one Undo takes back.
        var batch: UUID?
        /// The batch's actions in registration order; empty for a single action.
        fileprivate(set) var parts = [Action]()

        init(
            name: String,
            batch: UUID? = nil,
            perform: @escaping @MainActor (@escaping @MainActor (Outcome) -> Void) -> Void,
        ) {
            self.name = name
            self.batch = batch
            self.perform = perform
        }

        /// Performs `parts` last first, one after another, and commits with
        /// the inverses that committed, which run in the original order.
        static func batch(_ parts: [Action], id: UUID?) -> Action {
            var action = Action(name: parts.last?.name ?? "", batch: id) { completion in
                performParts(parts, from: parts.count - 1, inverses: [], completion: completion)
            }
            action.parts = parts
            return action
        }

        @MainActor private static func performParts(
            _ parts: [Action], from index: Int, inverses: [Action],
            completion: @escaping @MainActor (Outcome) -> Void,
        ) {
            guard index >= 0 else {
                completion(.committed(inverse: inverses.isEmpty ? nil : .batch(inverses, id: nil)))
                return
            }
            parts[index].perform { outcome in
                switch outcome {
                case .cancelled:
                    // Parts already taken back stay taken back; their inverses remain.
                    completion(inverses.isEmpty ? .cancelled : .committed(inverse: .batch(inverses, id: nil)))
                case .committed(let inverse):
                    performParts(
                        parts, from: index - 1, inverses: inverses + (inverse.map { [$0] } ?? []),
                        completion: completion,
                    )
                }
            }
        }
    }

    enum Outcome {
        case committed(inverse: Action?)
        case cancelled
    }

    // MARK: Private

    private enum Direction: Equatable {
        case undo, redo
    }

    private final class Marker: NSObject {
        // MARK: Internal

        let action: Action

        init(action: Action) { self.action = action }
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

    /// When a tab action last reached either stack, so Undo can tell whether
    /// typing in a page came after it.
    private(set) var lastTabActionDate = Date.distantPast

    private var epoch = UUID()
    private var pending: Pending?
    private var prepared: Prepared?
    private var isInvokingFoundation = false
    private var deferredActions = [Action]()

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
        var action = action
        // A later action of the same batch joins the entry on top of Undo.
        if let batch = action.batch, pending == nil, let top = marker(on: .undo), top.action.batch == batch {
            let parts = (top.action.parts.isEmpty ? [top.action] : top.action.parts) + [action]
            super.removeAllActions(withTarget: top)
            action = .batch(parts, id: batch)
        }
        beginUndoGrouping()
        installMarker(action)
        endUndoGrouping()
    }

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
        lastTabActionDate = Date()
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
