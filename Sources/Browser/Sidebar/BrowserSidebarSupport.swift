import SwiftUI

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
