import AppKit
import SwiftUI

/// Temporary mounting adapter while the browser window shell is migrated to AppKit.
struct BrowserFindBarOverlay: NSViewRepresentable {
    @ObservedObject var model: BrowserChromeModel

    let blockedLeadingInset: CGFloat

    static func dismantleNSView(_ view: BrowserFindBarNSView, coordinator _: ()) {
        view.update(
            query: view.queryField.stringValue,
            isPresented: false,
            canStep: false,
            focusRequestID: view.queryField.lastFocusRequestID,
            blockedLeadingInset: 0
        )
    }

    func makeNSView(context: Context) -> BrowserFindBarNSView {
        let view = BrowserFindBarNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: BrowserFindBarNSView, context _: Context) {
        view.queryField.focusPermission = { [weak model] in model?.isFindBarPresented == true }
        view.onQueryChanged = { [weak model] in model?.findQuery = $0 }
        view.onNext = { [weak model] in model?.findNextInPage() }
        view.onPrevious = { [weak model] in model?.findPreviousInPage() }
        view.onDismiss = { [weak model] in model?.dismissFindBar() }
        view.update(
            query: model.findQuery,
            isPresented: model.isFindBarPresented,
            canStep: model.canStepThroughFindMatches,
            focusRequestID: model.findBarFocusRequest,
            blockedLeadingInset: blockedLeadingInset
        )
    }
}
