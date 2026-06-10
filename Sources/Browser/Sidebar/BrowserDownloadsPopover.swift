import SwiftUI

// MARK: - BrowserDownloadsButton

struct BrowserDownloadsButton: View {
    @ObservedObject var downloadsModel: BrowserDownloadsModel
    @Binding var isPresented: Bool

    var systemImageName: String {
        downloadsModel.hasActiveDownloads ? "arrow.down.circle.fill" : "arrow.down.circle"
    }

    var body: some View {
        BrowserChromeControlButton(
            systemImageName: systemImageName,
            tooltipTitle: BrowserStrings.downloadsTitle,
            tooltipShortcut: nil,
            tooltipPlacement: .aboveCapsule,
            isSelected: isPresented || downloadsModel.hasActiveDownloads,
            pressEffect: .compress
        ) {
            isPresented.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if downloadsModel.hasActiveDownloads {
                Circle()
                    .fill(BrowserChromePalette.primaryText)
                    .frame(width: 5, height: 5)
                    .offset(x: -5, y: 5)
            }
        }
    }
}

// MARK: - BrowserDownloadsPopover

struct BrowserDownloadsPopover: View {
    @ObservedObject var downloadsModel: BrowserDownloadsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if downloadsModel.items.isEmpty {
                Text(BrowserStrings.downloadsEmpty)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(downloadsModel.items) { item in
                            BrowserDownloadRow(
                                item: item,
                                downloadsModel: downloadsModel
                            )

                            if item.id != downloadsModel.items.last?.id {
                                Divider()
                                    .padding(.leading, 34)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .topLeading)
    }

    var header: some View {
        HStack(spacing: 10) {
            Text(BrowserStrings.downloadsTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button(BrowserStrings.downloadsClearFinished) {
                downloadsModel.clearFinishedDownloads()
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
            .disabled(downloadsModel.finishedDownloadCount == 0)
        }
    }
}

// MARK: - BrowserDownloadRow

private struct BrowserDownloadRow: View {
    let item: BrowserDownloadItem

    @ObservedObject var downloadsModel: BrowserDownloadsModel

    var iconName: String {
        switch item.state {
        case .inProgress:
            "arrow.down"
        case .completed:
            "checkmark.circle.fill"
        case .canceled:
            "xmark.circle"
        case .interrupted:
            "exclamationmark.triangle"
        }
    }

    var showsFileActions: Bool {
        item.state == .completed && item.fileURL != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.state == .completed ? Color.green : .secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(downloadsModel.statusTitle(for: item))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text(downloadsModel.detailText(for: item))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if item.state == .inProgress {
                    ProgressView(value: item.progressFraction)
                        .controlSize(.small)
                }

                if showsFileActions {
                    HStack(spacing: 12) {
                        Button(BrowserStrings.downloadsOpen) {
                            downloadsModel.open(item)
                        }
                        .buttonStyle(.link)

                        Button(BrowserStrings.downloadsReveal) {
                            downloadsModel.reveal(item)
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
            }
        }
        .padding(.vertical, 9)
    }
}
