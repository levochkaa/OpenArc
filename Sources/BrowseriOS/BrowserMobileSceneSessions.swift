import UIKit
import WebKit

/// A UIKit session keeps one workspace and one save worker across reconnection.
/// Disconnecting a window must not discard a failed, unsaved snapshot.
@MainActor final class BrowserMobileSceneSessions {
    // MARK: Lifecycle

    init(factory: (@MainActor (String) -> Components)? = nil) {
        self.factory = factory ?? Self.makeComponents
    }

    // MARK: Internal

    struct Connection {
        // MARK: Internal

        let workspace: BrowserMobileWorkspace
        let contentView: UIView

        // MARK: Fileprivate

        fileprivate let sessionID: String
        fileprivate let attachmentID: UUID
    }

    struct Components {
        let workspace: BrowserMobileWorkspace
        let contentView: UIView
    }

    static let shared = BrowserMobileSceneSessions()

    func connect(sessionID: String) async throws -> Connection {
        // A discarded session normally cannot reconnect. Still serialize an
        // explicit reuse behind its final write instead of creating two writers.
        while let retirement = entries[sessionID]?.discardTask {
            await retirement.value
        }
        try Task.checkCancellation()
        let entry: Entry
        if let existing = entries[sessionID] {
            entry = existing
        } else {
            entry = Entry(components: factory(sessionID))
            entries[sessionID] = entry
            entry.restoreTask = Task {
                await entry.components.workspace.restore()
                entry.restoreTask = nil
            }
        }
        entry.components.workspace.setJavaScriptDialogPresentationActive(false)
        let attachmentID = UUID()
        entry.attachmentID = attachmentID
        return Connection(
            workspace: entry.components.workspace,
            contentView: entry.components.contentView,
            sessionID: sessionID,
            attachmentID: attachmentID
        )
    }

    func setActive(_ active: Bool, for connection: Connection) {
        guard let entry = currentEntry(for: connection) else { return }
        entry.components.workspace.setJavaScriptDialogPresentationActive(active)
    }

    func flush(_ connection: Connection) {
        guard let entry = currentEntry(for: connection), entry.flushTask == nil else { return }
        entry.flushTask = Task {
            await entry.restoreTask?.value
            await entry.components.workspace.flushPersistence()
            entry.flushTask = nil
        }
    }

    func disconnect(_ connection: Connection) {
        guard let entry = currentEntry(for: connection) else { return }
        entry.components.workspace.setJavaScriptDialogPresentationActive(false)
        flush(connection)
        entry.attachmentID = nil
        entry.components.workspace.onChange = nil
    }

    func discard(sessionIDs: Set<String>) {
        for sessionID in sessionIDs {
            guard let entry = entries[sessionID], entry.discardTask == nil else { continue }
            entry.components.workspace.setJavaScriptDialogPresentationActive(false)
            entry.attachmentID = nil
            entry.components.workspace.onChange = nil
            entry.discardTask = Task {
                // Explicit session discard ends this in-memory recovery scope.
                // Failed atomic saves leave the previous file intact.
                await entry.components.workspace.shutdown()
                await entry.restoreTask?.value
                await entry.flushTask?.value
                if self.entries[sessionID] === entry {
                    self.entries.removeValue(forKey: sessionID)
                }
                entry.discardTask = nil
            }
        }
    }

    func waitForPendingOperations() async {
        while true {
            let tasks = entries.values.flatMap { [$0.restoreTask, $0.flushTask, $0.discardTask].compactMap { $0 } }
            guard !tasks.isEmpty else { return }
            for task in tasks {
                await task.value
            }
        }
    }

    // MARK: Private

    private final class Entry {
        // MARK: Lifecycle

        init(components: Components) { self.components = components }

        // MARK: Internal

        let components: Components
        var attachmentID: UUID?
        var restoreTask: Task<Void, Never>?
        var flushTask: Task<Void, Never>?
        var discardTask: Task<Void, Never>?
    }

    private let factory: @MainActor (String) -> Components
    private var entries = [String: Entry]()

    private static func makeComponents(sessionID: String) -> Components {
        let engine = BrowserWebKitEngine(dataStore: .default())
        return Components(
            workspace: BrowserMobileWorkspace(
                engine: engine,
                sceneID: sessionID,
                profileLoader: { try await BrowserMobileProfileRegistry.shared.document()
                }
            ),
            contentView: engine.hostView
        )
    }

    private func currentEntry(for connection: Connection) -> Entry? {
        guard let entry = entries[connection.sessionID], entry.discardTask == nil,
              entry.attachmentID == connection.attachmentID
        else { return nil }
        return entry
    }
}
