import AppKit
import SwiftUI

enum BrowserAboutLayout {
    static let windowWidth: CGFloat = 440
    static let windowHeight: CGFloat = 420
}

struct BrowserAboutInfo {
    let applicationName: String
    let applicationVersionText: String
    let chromiumVersionText: String
    let copyrightText: String
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> BrowserAboutInfo {
        let applicationName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? BrowserStrings.applicationName
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? BrowserStrings.aboutUnknownVersion
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? BrowserStrings.aboutUnknownVersion
        let copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? BrowserStrings.aboutCopyright

        return BrowserAboutInfo(
            applicationName: applicationName,
            applicationVersionText: BrowserStrings.aboutApplicationVersion(
                marketingVersion: marketingVersion,
                buildVersion: buildVersion
            ),
            chromiumVersionText: BrowserStrings.aboutChromiumVersion(BrowserChromiumVersionString()),
            copyrightText: copyright,
            icon: NSApp.applicationIconImage
        )
    }
}

enum BrowserAboutResources {
    static let chromiumProjectURL = URL(string: "https://www.chromium.org/chromium-projects/")!
    static let chromiumCreditsLinkURL = URL(string: "tb://credits/")!

    static var theBrowserCreditsURL: URL {
        Bundle.main.url(forResource: "Credits", withExtension: "html")
            ?? URL(fileURLWithPath: "Credits.html")
    }
}

struct BrowserAboutView: View {
    let info: BrowserAboutInfo
    let openLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 22)

            Image(nsImage: info.icon)
                .resizable()
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(info.applicationName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(info.applicationVersionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(info.chromiumVersionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            Text(info.copyrightText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 18)

            Text(madePossibleText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 360)
                .padding(.top, 22)
                .environment(\.openURL, OpenURLAction { url in
                    openLink(url)
                    return .handled
                })

            Spacer(minLength: 28)
        }
        .frame(
            width: BrowserAboutLayout.windowWidth,
            height: BrowserAboutLayout.windowHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var madePossibleText: AttributedString {
        var text = AttributedString(BrowserStrings.aboutMadePossiblePrefix)

        var chromiumProject = AttributedString(BrowserStrings.aboutChromiumProjectLinkTitle)
        chromiumProject.link = BrowserAboutResources.chromiumProjectURL
        text.append(chromiumProject)

        text.append(AttributedString(BrowserStrings.aboutMadePossibleChromiumProjectSuffix))

        var chromiumCredits = AttributedString(BrowserStrings.aboutOpenSourceSoftwareLinkTitle)
        chromiumCredits.link = BrowserAboutResources.chromiumCreditsLinkURL
        text.append(chromiumCredits)

        text.append(AttributedString(BrowserStrings.aboutMadePossibleOtherPrefix))

        var theBrowserCredits = AttributedString(BrowserStrings.aboutOpenSourceSoftwareLinkTitle)
        theBrowserCredits.link = BrowserAboutResources.theBrowserCreditsURL
        text.append(theBrowserCredits)

        text.append(AttributedString(BrowserStrings.aboutMadePossibleSuffix))
        return text
    }
}
