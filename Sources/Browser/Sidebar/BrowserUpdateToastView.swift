import SwiftUI

// MARK: - BrowserUpdateToastView

struct BrowserUpdateToastView: View {
    @ObservedObject var updateController: BrowserUpdateController

    var body: some View {
        if let toast = updateController.toast {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(toast.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button(action: updateController.installDownloadedUpdateNow) {
                    Text(toast.actionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: updateController.dismissToast) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BrowserStrings.updateDismissAction)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
