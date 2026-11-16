// BrowserCoalescedRefresh.swift

import Combine
import Foundation

/// Runs its action once on the next main run loop pass, however many changes ask for it
/// before then, so a click that changes ten model values redraws the window once.
@MainActor final class BrowserCoalescedRefresh {
    // MARK: Internal

    /// How many times the action ran.
    private(set) var runCount = 0

    // MARK: Private

    private let requests = PassthroughSubject<Void, Never>()
    private var isRequested = false
    private var observations = Set<AnyCancellable>()

    init(_ action: @escaping @MainActor () -> Void) {
        requests.receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.isRequested = false
                runCount += 1
                action()
            }
            .store(in: &observations)
    }

    /// Asks for a run on each value; values may arrive on any thread.
    func observe(_ publishers: [AnyPublisher<Void, Never>]) {
        for publisher in publishers {
            publisher.sink { [weak self] _ in
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { self?.request() }
                    return
                }
                MainActor.assumeIsolated { self?.request() }
            }
            .store(in: &observations)
        }
    }

    func request() {
        guard !isRequested else { return }
        isRequested = true
        requests.send()
    }
}
