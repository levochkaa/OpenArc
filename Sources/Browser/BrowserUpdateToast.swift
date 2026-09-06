import Foundation

// MARK: - BrowserUpdateToast

struct BrowserUpdateToast: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let actionTitle: String
}
