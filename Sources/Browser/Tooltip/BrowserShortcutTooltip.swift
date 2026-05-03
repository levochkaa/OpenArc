import AppKit
import QuartzCore
import SwiftUI

// MARK: - BrowserTooltipPlacement

enum BrowserTooltipPlacement {
    case belowLeading
    case aboveCapsule
}

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
    static var defaultValue = [BrowserTooltipPreferenceEntry]()

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
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.id) { entry in
                    BrowserShortcutTooltip(
                        title: entry.title,
                        caption: entry.caption,
                        shortcut: entry.shortcut,
                        placement: entry.placement
                    )
                    .fixedSize()
                    .modifier(BrowserTooltipPlacementModifier(entry: entry))
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

// MARK: - BrowserTooltipPlacementModifier

struct BrowserTooltipPlacementModifier: ViewModifier {
    let entry: BrowserResolvedTooltipEntry

    func body(content: Content) -> some View {
        switch entry.placement {
        case .belowLeading:
            content.offset(
                x: entry.sourceFrame.minX
                    + entry.sourceFrame.width * BrowserChromeLayout.tooltipAnchorXFraction,
                y: entry.sourceFrame.minY
                    + entry.sourceFrame.height * BrowserChromeLayout.tooltipAnchorYFraction
            )
        case .aboveCapsule:
            content.position(
                x: entry.sourceFrame.midX,
                y: entry.sourceFrame.minY - BrowserChromeLayout.tooltipVerticalGap - BrowserChromeLayout
                    .tooltipKeyHeight
            )
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
                    .fixedSize()

                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(BrowserChromePalette.tooltipCaption)
                        .fixedSize()
                }
            }

            if let shortcut {
                BrowserShortcutKeyCapsView(shortcut: shortcut)
            }
        }
        .padding(.horizontal, BrowserChromeLayout.tooltipHorizontalPadding)
        .padding(.vertical, BrowserChromeLayout.tooltipVerticalPadding)
        .background(tooltipBackground)
        .fixedSize()
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
