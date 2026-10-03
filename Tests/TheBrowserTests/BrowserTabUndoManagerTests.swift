import Foundation
import Testing

// MARK: - BrowserTabUndoManagerTests

@Suite(.serialized)
@MainActor struct BrowserTabUndoManagerTests {
    @Test func heldUndoCancelAndRepeatedCommandsKeepOriginalHistory() {
        let manager = makeTabUndoManager()
        let gate = TabUndoGate()
        manager.registerTabAction(.init(name: "Close Tab", perform: gate.perform))
        manager.undo()
        #expect(gate.calls == 1 && manager.isTabTransitionPending)
        #expect(!manager.canUndo && !manager.canRedo)
        #expect(manager.undoActionName == "Close Tab" && manager.undoCount == 1)
        manager.undo()
        manager.redo()
        manager.undoNestedGroup()
        #expect(gate.calls == 1)
        gate.complete(.cancelled)
        #expect(!manager.isTabTransitionPending && manager.canUndo && !manager.canRedo)
        #expect(manager.undoActionName == "Close Tab")
        manager.undo()
        #expect(gate.calls == 2)
        gate.complete(.committed(inverse: nil))
        #expect(!manager.canUndo && !manager.canRedo)
    }

    @Test func redoStaysOnRedoSideUntilCommitAndRunsBusinessEffectOnce() {
        let manager = makeTabUndoManager()
        let redoGate = TabUndoGate()
        let undoGate = TabUndoGate()
        manager.registerTabAction(.init(name: "Restore Tab") { completion in
            completion(.committed(inverse: .init(name: "Close Tab", perform: redoGate.perform)))
        })
        manager.undo()
        #expect(manager.canRedo && !manager.canUndo)
        #expect(manager.redoActionName == "Close Tab")
        manager.redo()
        manager.redo()
        #expect(redoGate.calls == 1 && manager.isTabTransitionPending)
        #expect(manager.redoCount == 1 && manager.undoCount == 0)
        redoGate.complete(.cancelled)
        #expect(manager.canRedo && manager.redoActionName == "Close Tab")
        manager.redo()
        redoGate.complete(.committed(inverse: .init(name: "Restore Tab", perform: undoGate.perform)))
        #expect(redoGate.calls == 2 && !manager.isTabTransitionPending)
        #expect(manager.canUndo && !manager.canRedo && manager.undoActionName == "Restore Tab")
        manager.undo()
        #expect(undoGate.calls == 1)
        undoGate.complete(.committed(inverse: nil))
    }

    @Test func pendingUndoPreservesNewNativeAndTabActionsWithoutRevivingRedo() {
        let manager = makeTabUndoManager()
        let gate = TabUndoGate()
        let native = NativeUndoValue()
        var newestTabUndone = false
        manager.registerTabAction(.init(name: "Old Close", perform: gate.perform))
        manager.undo()
        registerNativeEdit(manager, target: native, value: 1)
        manager.registerTabAction(.init(name: "New Tab") { completion in
            newestTabUndone = true
            completion(.committed(inverse: nil))
        })
        gate.complete(.committed(inverse: .init(name: "Obsolete Redo") { _ in Issue.record("Old redo revived") }))
        #expect(manager.undoCount == 2 && !manager.canRedo)
        #expect(manager.undoActionName == "New Tab")
        manager.undo()
        #expect(newestTabUndone && native.value == 1)
        #expect(manager.undoActionName == "Typing")
        manager.undo()
        #expect(native.value == 0 && !manager.canUndo)
    }

    @Test func pendingRedoCommitsAfterNewNativeEditAsNewestUndo() {
        let manager = makeTabUndoManager()
        let gate = TabUndoGate()
        let native = NativeUndoValue()
        var redoInverseCalls = 0
        manager.registerTabAction(.init(name: "Restore") { completion in
            completion(.committed(inverse: .init(name: "Close", perform: gate.perform)))
        })
        manager.undo()
        manager.redo()
        registerNativeEdit(manager, target: native, value: 1)
        #expect(manager.redoCount == 0)
        gate.complete(.committed(inverse: .init(name: "Restore After Close") { completion in
            redoInverseCalls += 1
            completion(.committed(inverse: nil))
        }))
        #expect(manager.undoCount == 2 && !manager.canRedo)
        #expect(manager.undoActionName == "Restore After Close")
        manager.undo()
        #expect(redoInverseCalls == 1 && native.value == 1)
        manager.undo()
        #expect(native.value == 0)
    }

    @Test func resetAndDuplicateCompletionsCannotMoveAnotherEntry() {
        let manager = makeTabUndoManager()
        let old = TabUndoGate()
        let current = TabUndoGate()
        manager.registerTabAction(.init(name: "Old", perform: old.perform))
        manager.undo()
        manager.removeAllActions()
        manager.registerTabAction(.init(name: "Current", perform: current.perform))
        old.complete(.committed(inverse: .init(name: "Stale") { _ in Issue.record("Stale callback used") }))
        #expect(manager.canUndo && !manager.canRedo && manager.undoActionName == "Current")
        manager.undo()
        let duplicateReply = current.reply
        current.complete(.committed(inverse: nil))
        duplicateReply?(.committed(inverse: .init(name: "Duplicate") { _ in Issue.record("Duplicate callback used") }))
        #expect(!manager.canUndo && !manager.canRedo && !manager.isTabTransitionPending)
    }

    @Test func targetedRemovalInvalidatesOnlyMatchingPendingMarker() throws {
        let manager = makeTabUndoManager()
        let native = NativeUndoValue()
        let gate = TabUndoGate()
        registerNativeEdit(manager, target: native, value: 1)
        manager.registerTabAction(.init(name: "Close", perform: gate.perform))
        let target = try #require(manager.undoActionUserInfoValue(forKey: BrowserTabUndoManager.tabActionKey))
        manager.undo()
        manager.removeAllActions(withTarget: NSObject())
        #expect(manager.isTabTransitionPending)
        manager.removeAllActions(withTarget: target)
        #expect(!manager.isTabTransitionPending && manager.undoActionName == "Typing")
        gate.complete(.committed(inverse: .init(name: "Stale") { _ in Issue.record("Removed target restored") }))
        #expect(manager.undoCount == 1 && !manager.canRedo)
        manager.undo()
        #expect(native.value == 0)
    }

    @Test func persistenceGateBlocksTabActionsButNativeUndoAndRedoRemainAvailable() {
        let manager = makeTabUndoManager()
        let native = NativeUndoValue()
        let gate = TabUndoGate()
        manager.canPerformTabAction = { false }
        manager.registerTabAction(.init(name: "Close", perform: gate.perform))
        #expect(!manager.canUndo)
        manager.undo()
        #expect(gate.calls == 0)
        registerNativeEdit(manager, target: native, value: 1)
        #expect(manager.canUndo)
        manager.undo()
        #expect(native.value == 0 && manager.canRedo && !manager.canUndo)
        manager.redo()
        #expect(native.value == 1 && manager.canUndo)
        manager.undo()
        manager.canPerformTabAction = { true }
        #expect(manager.canUndo)
        manager.undo()
        #expect(gate.calls == 1)
        gate.complete(.cancelled)
    }

    @Test func tabRegistrationWaitsForNativeGroupAndPreservesItsAtomicity() {
        let manager = makeTabUndoManager()
        let native = NativeUndoValue()
        let gate = TabUndoGate()
        manager.beginUndoGrouping()
        native.set(1, manager: manager)
        manager.beginUndoGrouping()
        manager.registerTabAction(.init(name: "Close", perform: gate.perform))
        manager.undo()
        #expect(gate.calls == 0 && manager.groupingLevel == 2)
        manager.endUndoGrouping()
        native.set(2, manager: manager)
        manager.setActionName("Typing Group")
        manager.endUndoGrouping()
        #expect(manager.groupingLevel == 0 && manager.undoCount == 2)
        #expect(manager.undoActionName == "Close")
        manager.undo()
        gate.complete(.committed(inverse: nil))
        #expect(manager.undoActionName == "Typing Group")
        manager.undo()
        #expect(native.value == 0 && !manager.canUndo)
    }

    @Test func pendingRedoInverseWaitsForOpenNativeGroupAndComesAfterIt() {
        let manager = makeTabUndoManager()
        let native = NativeUndoValue()
        let gate = TabUndoGate()
        manager.registerTabAction(.init(name: "Restore") { completion in
            completion(.committed(inverse: .init(name: "Close", perform: gate.perform)))
        })
        manager.undo()
        manager.redo()
        manager.beginUndoGrouping()
        native.set(1, manager: manager)
        manager.setActionName("Typing")
        gate.complete(.committed(inverse: .init(name: "Restore") { $0(.committed(inverse: nil)) }))
        #expect(manager.groupingLevel == 1 && !manager.isTabTransitionPending)
        manager.endUndoGrouping()
        #expect(manager.undoActionName == "Restore" && manager.undoCount == 2)
        manager.undo()
        #expect(manager.undoActionName == "Typing" && native.value == 1)
        manager.undo()
        #expect(native.value == 0)
    }
}

@MainActor private func makeTabUndoManager() -> BrowserTabUndoManager {
    let manager = BrowserTabUndoManager()
    manager.groupsByEvent = false
    return manager
}

// MARK: - TabUndoGate

@MainActor private final class TabUndoGate {
    // MARK: Internal

    private(set) var calls = 0

    var reply: (@MainActor (BrowserTabUndoManager.Outcome) -> Void)? { completion }

    func perform(_ completion: @escaping @MainActor (BrowserTabUndoManager.Outcome) -> Void) {
        calls += 1
        self.completion = completion
    }

    func complete(_ outcome: BrowserTabUndoManager.Outcome) {
        let reply = completion
        completion = nil
        reply?(outcome)
    }

    // MARK: Private

    private var completion: (@MainActor (BrowserTabUndoManager.Outcome) -> Void)?
}

// MARK: - NativeUndoValue

@MainActor private final class NativeUndoValue: NSObject {
    private(set) var value = 0

    func set(_ value: Int, manager: UndoManager) {
        let previous = self.value
        self.value = value
        manager.registerUndo(withTarget: self) { [weak manager] target in
            guard let manager else { return }
            target.set(previous, manager: manager)
        }
    }
}

@MainActor private func registerNativeEdit(_ manager: UndoManager, target: NativeUndoValue, value: Int) {
    manager.beginUndoGrouping()
    target.set(value, manager: manager)
    manager.setActionName("Typing")
    manager.endUndoGrouping()
}
