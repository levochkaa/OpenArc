import Foundation

// MARK: - BrowserMobileSidebarHoverScheduling

@MainActor protocol BrowserMobileSidebarHoverScheduling: AnyObject {
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void)
    func cancel()
}

// MARK: - BrowserMobileSidebarHoverScheduler

@MainActor final class BrowserMobileSidebarHoverScheduler: BrowserMobileSidebarHoverScheduling {
    // MARK: Internal

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        cancel()
        task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: Private

    private var task: Task<Void, Never>?
}
