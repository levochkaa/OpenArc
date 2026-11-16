// BrowserSidebarPresentation.swift

/// How the window shows the sidebar's chrome, compared after each layout of the window.
struct BrowserSidebarPresentation: Equatable {
    var showsWindowControls: Bool
    var isOverlay: Bool
    var fadesOverlayBorder: Bool

    /// A layout that moved nothing and changed no presentation follows a refresh that
    /// already drew the sidebar, so only a finished animation or a new presentation
    /// draws it again.
    static func needsRefresh(from old: Self, to new: Self, afterAnimation: Bool) -> Bool {
        afterAnimation || old != new
    }
}
