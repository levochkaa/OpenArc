// BrowserAboutView.swift

import AppKit

@MainActor extension BrowserAboutInfo {
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
                buildVersion: buildVersion,
            ),
            chromiumVersionText: BrowserStrings.aboutChromiumVersion(BrowserChromiumVersionString()),
            copyrightText: copyright,
            icon: NSApp.applicationIconImage,
        )
    }
}
