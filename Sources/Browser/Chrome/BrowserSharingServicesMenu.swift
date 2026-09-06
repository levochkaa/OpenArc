import AppKit
import SwiftUI

// MARK: - BrowserSharingServicesMenu

struct BrowserSharingServicesMenu: View {
    let sharingItems: [Any]
    let subject: String

    var body: some View {
        Menu(BrowserStrings.tabShareAction) {
            let sharingServices = BrowserShareMenuServiceProvider.sharingServices(for: sharingItems)

            ForEach(Array(sharingServices.enumerated()), id: \.offset) { _, service in
                Button {
                    service.subject = subject
                    service.perform(withItems: sharingItems)
                } label: {
                    Label {
                        Text(service.menuItemTitle)
                    } icon: {
                        Image(nsImage: service.image)
                    }
                }
            }
        }
    }
}
