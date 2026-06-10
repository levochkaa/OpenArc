import SwiftUI

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

// MARK: - BrowserSidebarProfileIndicator

struct BrowserSidebarProfileIndicator: View {
    let profileName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrowserChromePalette.secondaryText)

            Text(profileName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(BrowserChromePalette.primaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(BrowserChromePalette.currentURLRow)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
