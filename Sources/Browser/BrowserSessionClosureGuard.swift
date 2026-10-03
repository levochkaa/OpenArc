import Foundation

/// Runs before teardown. Modal confirmation can deliver new model callbacks,
/// so every profile is checked again after the user responds.
@MainActor enum BrowserSessionClosureGuard {
    enum Decision {
        case cancel
        case retry
        case discardUnsaved
    }

    static func prepare(
        models: () -> [BrowserChromeModel],
        confirmation: ([BrowserChromeModel]) -> Decision
    ) -> Bool {
        while true {
            let failed = models().filter { !$0.prepareSessionForClosure() }
            guard !failed.isEmpty else { return true }
            switch confirmation(failed) {
            case .cancel:
                return false
            case .retry:
                continue
            case .discardUnsaved:
                // Discard is the final choice for this closure. Do not disable
                // one profile and then let a later prompt cancel the whole quit.
                for model in models() where !model.prepareSessionForClosure() {
                    model.discardUnsavedSessionForClosure()
                }
                return true
            }
        }
    }
}
