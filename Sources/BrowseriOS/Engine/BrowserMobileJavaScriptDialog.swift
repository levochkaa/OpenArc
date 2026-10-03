import Foundation

// MARK: - BrowserMobileJavaScriptDialog

/// Transient page UI. A token identifies one WebKit completion, never persisted.
struct BrowserMobileJavaScriptDialog: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case alert
        case confirm
        case prompt(defaultText: String?)
    }

    let id: UUID
    let runtimeID: String
    let origin: String
    let message: String
    let kind: Kind
}

// MARK: - BrowserMobileJavaScriptDialogResponse

enum BrowserMobileJavaScriptDialogResponse: Equatable, Sendable {
    /// An accepted prompt can contain an empty string, distinct from Cancel.
    case accept(text: String?)
    case cancel
}
