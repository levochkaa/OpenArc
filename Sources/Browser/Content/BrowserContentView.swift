import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserContentView

struct BrowserContentView: View {
    let hostView: NSView
    let isContextReady: Bool
    let hasSelectedTab: Bool
    let isSidebarVisible: Bool
    let usesWindowContentInsets: Bool

    var contentCornerRadius: CGFloat {
        shouldRoundLeadingCorners || shouldRoundTrailingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0
    }

    var shouldRoundLeadingCorners: Bool {
        isSidebarVisible || usesWindowContentInsets
    }

    var shouldRoundTrailingCorners: Bool {
        usesWindowContentInsets
    }

    var maskedContentCorners: CACornerMask {
        var corners: CACornerMask = []

        if shouldRoundLeadingCorners {
            corners.insert(.layerMinXMinYCorner)
            corners.insert(.layerMinXMaxYCorner)
        }

        if shouldRoundTrailingCorners {
            corners.insert(.layerMaxXMinYCorner)
            corners.insert(.layerMaxXMaxYCorner)
        }

        return corners
    }

    var contentShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: shouldRoundLeadingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0,
                bottomLeading: shouldRoundLeadingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0,
                bottomTrailing: shouldRoundTrailingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0,
                topTrailing: shouldRoundTrailingCorners ? BrowserChromeLayout.leadingContentCornerRadius : 0
            ),
            style: .continuous
        )
    }

    var body: some View {
        BrowserViewportHostRepresentable(
            hostView: hostView,
            cornerRadius: contentCornerRadius,
            maskedCorners: maskedContentCorners
        )
        .opacity(hasSelectedTab ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if !isContextReady {
                ZStack {
                    Rectangle()
                        .fill(BrowserChromePalette.contentBackground)

                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(BrowserChromePalette.primaryText)
                        Text(BrowserStrings.loadingLaunchingBrowser)
                            .font(.system(size: 12))
                            .foregroundStyle(BrowserChromePalette.secondaryText)
                    }
                }
                .clipShape(contentShape)
            }
        }
    }
}

// MARK: @MainActor Equatable

extension BrowserContentView: @MainActor Equatable {
    static func == (lhs: BrowserContentView, rhs: BrowserContentView) -> Bool {
        ObjectIdentifier(lhs.hostView) == ObjectIdentifier(rhs.hostView)
            && lhs.isContextReady == rhs.isContextReady
            && lhs.hasSelectedTab == rhs.hasSelectedTab
            && lhs.isSidebarVisible == rhs.isSidebarVisible
            && lhs.usesWindowContentInsets == rhs.usesWindowContentInsets
    }
}

// MARK: - BrowserViewportHostRepresentable

struct BrowserViewportHostRepresentable: NSViewRepresentable {
    let hostView: NSView
    let cornerRadius: CGFloat
    let maskedCorners: CACornerMask

    func makeNSView(context _: Context) -> BrowserViewportClipView {
        let clipView = BrowserViewportClipView(hostView: hostView)
        clipView.updateClipping(cornerRadius: cornerRadius, maskedCorners: maskedCorners)
        return clipView
    }

    func updateNSView(_ nsView: BrowserViewportClipView, context _: Context) {
        nsView.update(hostView: hostView)
        nsView.updateClipping(cornerRadius: cornerRadius, maskedCorners: maskedCorners)
    }
}

// MARK: - BrowserViewportClipView

final class BrowserViewportClipView: NSView {
    // MARK: Lifecycle

    init(hostView: NSView) {
        self.hostedView = hostView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        attachHostedViewIfNeeded()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    var hostedView: NSView

    override func layout() {
        super.layout()
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }

    func update(hostView: NSView) {
        guard hostedView !== hostView else {
            attachHostedViewIfNeeded()
            return
        }

        hostedView = hostView
        attachHostedViewIfNeeded()
        needsLayout = true
    }

    func updateClipping(cornerRadius: CGFloat, maskedCorners: CACornerMask) {
        guard let layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = max(cornerRadius, 0)
        layer.maskedCorners = maskedCorners
        CATransaction.commit()
    }

    // MARK: Private

    private func attachHostedViewIfNeeded() {
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }

        hostedView.autoresizingMask = [.width, .height]
        if hostedView.frame != bounds {
            hostedView.frame = bounds
        }
    }
}
