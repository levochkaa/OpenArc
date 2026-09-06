import AppKit
import Combine

// MARK: - BrowserSidebarTabDragPreviewStore

final class BrowserSidebarTabDragPreviewStore: ObservableObject {
    @Published var preview: BrowserSidebarTabDragPreviewState?

    func begin(_ preview: BrowserSidebarTabDragPreviewState) {
        guard self.preview != preview else {
            return
        }

        self.preview = preview
    }

    func update(location: CGPoint, size: CGSize) {
        guard var preview else {
            return
        }

        guard preview.location != location || preview.size != size else {
            return
        }

        preview.update(location: location, size: size)
        self.preview = preview
    }

    func clear() {
        guard preview != nil else {
            return
        }

        preview = nil
    }
}
