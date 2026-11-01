// BrowserReloadSymbolState.swift

import Foundation

// MARK: - BrowserReloadSymbolState

/// Whether the reload button shows Stop: only once a page has been loading for a moment,
/// so a quick load never flashes it.
@MainActor final class BrowserReloadSymbolState {
    // MARK: Private

    private static let delayNanoseconds: UInt64 = 500_000_000

    // MARK: Internal

    private(set) var showsStop = false

    private let onChange: () -> Void
    private var task: Task<Void, Never>?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        task?.cancel()
    }

    func update(isLoading: Bool) {
        guard isLoading else {
            task?.cancel()
            task = nil
            showsStop = false
            return
        }
        guard !showsStop, task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            task = nil
            showsStop = true
            onChange()
        }
    }
}
