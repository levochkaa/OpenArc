import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserShortcutTooltipModifier

struct BrowserShortcutTooltipModifier: ViewModifier {
    @EnvironmentObject var tooltipCoordinator: BrowserTooltipCoordinator

    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
    let isPresented: Bool

    @State var tooltipID = UUID()

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: BrowserTooltipPreferenceKey.self, value: .bounds) { bounds in
                guard tooltipCoordinator.activeTooltipID == tooltipID else {
                    return []
                }

                return [
                    BrowserTooltipPreferenceEntry(
                        id: tooltipID,
                        bounds: bounds,
                        title: title,
                        caption: caption,
                        shortcut: shortcut,
                        placement: placement
                    ),
                ]
            }
            .onAppear {
                if isPresented {
                    tooltipCoordinator.setHovering(true, for: tooltipID)
                }
            }
            .onChange(of: isPresented) { _, isPresented in
                tooltipCoordinator.setHovering(isPresented, for: tooltipID)
            }
            .onDisappear {
                tooltipCoordinator.setHovering(false, for: tooltipID)
            }
    }
}

extension View {
    func browserTooltip(
        title: String,
        caption: String? = nil,
        shortcut: BrowserKeyboardShortcut?,
        placement: BrowserTooltipPlacement = .belowLeading,
        isPresented: Bool
    ) -> some View {
        modifier(
            BrowserShortcutTooltipModifier(
                title: title,
                caption: caption,
                shortcut: shortcut,
                placement: placement,
                isPresented: isPresented
            )
        )
    }
}

// MARK: - BrowserTooltipPreferenceEntry

struct BrowserTooltipPreferenceEntry {
    let id: UUID
    let bounds: Anchor<CGRect>
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
}

// MARK: - BrowserTooltipPreferenceKey

struct BrowserTooltipPreferenceKey: PreferenceKey {
    static let defaultValue = [BrowserTooltipPreferenceEntry]()

    static func reduce(value: inout [BrowserTooltipPreferenceEntry], nextValue: () -> [BrowserTooltipPreferenceEntry]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - BrowserResolvedTooltipEntry

struct BrowserResolvedTooltipEntry {
    let id: UUID
    let sourceFrame: CGRect
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement
}

// MARK: - BrowserTooltipOverlay

struct BrowserTooltipOverlay: View {
    // MARK: Internal

    let entries: [BrowserResolvedTooltipEntry]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.id) { entry in
                    BrowserTooltipPresenter(entry: entry, containerSize: proxy.size)
                        .transition(transition(for: entry.placement))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: entries.map(\.id))
    }

    // MARK: Private

    private func transition(for placement: BrowserTooltipPlacement) -> AnyTransition {
        switch placement {
        case .belowLeading:
            .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading))
        case .aboveCapsule:
            .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
        }
    }
}

// MARK: - BrowserTooltipPresenter

struct BrowserTooltipPresenter: View {
    // MARK: Internal

    let entry: BrowserResolvedTooltipEntry
    let containerSize: CGSize

    var body: some View {
        BrowserTooltipMeasuredLayout(maximumWidth: maximumTooltipWidth) {
            BrowserShortcutTooltip(
                title: entry.title,
                caption: entry.caption,
                shortcut: entry.shortcut,
                placement: entry.placement
            )
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: BrowserTooltipSizePreferenceKey.self,
                    value: proxy.size
                )
            }
        }
        .onPreferenceChange(BrowserTooltipSizePreferenceKey.self) { tooltipSize = $0 }
        .position(
            x: resolvedTopLeft.x + tooltipSize.width / 2,
            y: resolvedTopLeft.y + tooltipSize.height / 2
        )
    }

    // MARK: Private

    @State private var tooltipSize = CGSize.zero

    private var maximumTooltipWidth: CGFloat {
        min(
            BrowserChromeLayout.tooltipMaximumWidth,
            max(containerSize.width - BrowserChromeLayout.tooltipViewportPadding * 2, 0)
        )
    }

    private var resolvedTopLeft: CGPoint {
        BrowserTooltipPlacementResolver.topLeft(
            sourceFrame: entry.sourceFrame,
            tooltipSize: tooltipSize,
            containerSize: containerSize,
            placement: entry.placement,
            verticalGap: BrowserChromeLayout.tooltipVerticalGap,
            anchorXFraction: BrowserChromeLayout.tooltipAnchorXFraction,
            anchorYFraction: BrowserChromeLayout.tooltipAnchorYFraction,
            viewportPadding: BrowserChromeLayout.tooltipViewportPadding
        )
    }
}

// MARK: - BrowserTooltipMeasuredLayout

struct BrowserTooltipMeasuredLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else {
            return .zero
        }

        let idealSize = subview.sizeThatFits(.unspecified)
        let constrainedSize = idealSize.width > maximumWidth
            ? subview.sizeThatFits(ProposedViewSize(width: maximumWidth, height: nil))
            : idealSize

        return BrowserTooltipMeasuredSizeResolver.resolvedSize(
            idealSize: idealSize,
            constrainedSize: constrainedSize,
            maximumWidth: maximumWidth
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let subview = subviews.first else {
            return
        }

        subview.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

// MARK: - BrowserTooltipSizePreferenceKey

struct BrowserTooltipSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let nextValue = nextValue()
        if nextValue != .zero {
            value = nextValue
        }
    }
}

// MARK: - BrowserShortcutTooltip

struct BrowserShortcutTooltip: View {
    let title: String
    let caption: String?
    let shortcut: BrowserKeyboardShortcut?
    let placement: BrowserTooltipPlacement

    var tooltipCornerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: BrowserChromeLayout.tooltipCornerRadius,
                bottomTrailing: BrowserChromeLayout.tooltipCornerRadius,
                topTrailing: BrowserChromeLayout.tooltipCornerRadius
            ),
            style: .continuous
        )
    }

    var body: some View {
        HStack(spacing: BrowserChromeLayout.tooltipContentSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BrowserChromePalette.tooltipText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.tooltipCaption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let shortcut {
                BrowserShortcutKeyCapsView(shortcut: shortcut)
            }
        }
        .padding(.horizontal, BrowserChromeLayout.tooltipHorizontalPadding)
        .padding(.vertical, BrowserChromeLayout.tooltipVerticalPadding)
        .background(tooltipBackground)
        .shadow(
            color: BrowserChromePalette.tooltipShadow,
            radius: 18,
            x: 0,
            y: 10
        )
    }

    var tooltipBackground: some View {
        Group {
            switch placement {
            case .belowLeading:
                tooltipCornerShape
                    .fill(BrowserChromePalette.tooltipBackground)
                    .overlay(
                        tooltipCornerShape.stroke(
                            BrowserChromePalette.tooltipBorder,
                            lineWidth: BrowserChromeLayout.tooltipBorderWidth
                        )
                    )
            case .aboveCapsule:
                Capsule(style: .continuous)
                    .fill(BrowserChromePalette.tooltipBackground)
                    .overlay(
                        Capsule(style: .continuous).stroke(
                            BrowserChromePalette.tooltipBorder,
                            lineWidth: BrowserChromeLayout.tooltipBorderWidth
                        )
                    )
            }
        }
    }
}

// MARK: - BrowserShortcutKeyCapsView

struct BrowserShortcutKeyCapsView: View {
    let shortcut: BrowserKeyboardShortcut

    var body: some View {
        HStack(spacing: BrowserChromeLayout.tooltipKeySpacing) {
            ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { _, keyCap in
                Text(keyCap)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BrowserChromePalette.tooltipKeyText)
                    .padding(.horizontal, BrowserChromeLayout.tooltipKeyHorizontalPadding)
                    .frame(minWidth: BrowserChromeLayout.tooltipKeyHeight)
                    .frame(height: BrowserChromeLayout.tooltipKeyHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(BrowserChromePalette.tooltipKeyBackground)
                    )
                    .shadow(
                        color: BrowserChromePalette.tooltipKeyShadow,
                        radius: 2,
                        x: 0,
                        y: 1
                    )
            }
        }
    }
}

extension View {
    func browserKeyboardShortcut(_ shortcut: BrowserKeyboardShortcut) -> some View {
        keyboardShortcut(shortcut.swiftUIKeyEquivalent, modifiers: shortcut.swiftUIModifiers)
    }
}

extension BrowserKeyboardShortcut {
    var swiftUIKeyEquivalent: KeyEquivalent {
        guard let keyEquivalent = keyEquivalent.first else {
            return KeyEquivalent(Character(" "))
        }

        return KeyEquivalent(keyEquivalent)
    }

    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []

        if modifiers.contains(.control) {
            result.insert(.control)
        }

        if modifiers.contains(.option) {
            result.insert(.option)
        }

        if modifiers.contains(.shift) {
            result.insert(.shift)
        }

        if modifiers.contains(.command) {
            result.insert(.command)
        }

        return result
    }
}
