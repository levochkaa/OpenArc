import AppKit
import QuartzCore
import SwiftUI

struct BrowserVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode = NSVisualEffectView.BlendingMode.withinWindow
    var state = NSVisualEffectView.State.active

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.state = state
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context _: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}
