import SwiftUI

enum BrowserSettingsLayout {
    static let windowWidth: CGFloat = 360
    static let windowHeight: CGFloat = 132
    static let contentPadding: CGFloat = 20
    static let contentSpacing: CGFloat = 16
    static let pickerWidth: CGFloat = 150
}

struct BrowserSettingsView: View {
    private enum Tab: Hashable {
        case general
    }

    @ObservedObject var model: BrowserChromeModel
    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettingsTab
                .tabItem {
                    Text(BrowserStrings.settingsGeneralTab)
                }
                .tag(Tab.general)
        }
        .frame(width: BrowserSettingsLayout.windowWidth, height: BrowserSettingsLayout.windowHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsLayout.contentSpacing) {
            HStack(alignment: .center, spacing: 12) {
                Text(BrowserStrings.settingsTemporaryTabsLifetimeLabel)
                    .font(.system(size: 13))

                Spacer(minLength: 0)

                Picker(
                    "",
                    selection: Binding(
                        get: { model.temporaryTabLifetime },
                        set: { model.setTemporaryTabLifetime($0) }
                    )
                ) {
                    ForEach(BrowserTemporaryTabLifetime.allCases, id: \.self) { lifetime in
                        Text(BrowserStrings.title(for: lifetime))
                            .tag(lifetime)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: BrowserSettingsLayout.pickerWidth, alignment: .trailing)
            }

            Spacer(minLength: 0)
        }
        .padding(BrowserSettingsLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
