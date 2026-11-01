// BrowserCommandBarLayout.swift

import AppKit
import QuartzCore

// MARK: - BrowserCommandBarOverlayStyle

enum BrowserCommandBarOverlayStyle: Equatable {
    case standard
    case compact(anchorFrame: CGRect?, sidebarWidth: CGFloat, matchesAnchorWidth: Bool)

    // MARK: Internal

    var fontSize: CGFloat {
        switch self {
        case .standard:
            20
        case .compact:
            BrowserChromeLayout.compactCommandBarFontSize
        }
    }

    var symbolSize: CGFloat {
        switch self {
        case .standard:
            18
        case .compact:
            BrowserChromeLayout.compactCommandBarSymbolSize
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarCornerRadius
        case .compact:
            BrowserChromeLayout.compactCommandBarCornerRadius
        }
    }

    var fieldHeight: CGFloat {
        switch self {
        case .standard:
            BrowserChromeLayout.commandBarFieldHeight
        case .compact:
            BrowserChromeLayout.compactCommandBarFieldHeight
        }
    }

    var textFieldVerticalOffset: CGFloat {
        switch self {
        case .standard:
            0
        case .compact:
            BrowserChromeLayout.compactCommandBarTextFieldVerticalOffset
        }
    }

    var selectsTextOnFocus: Bool {
        switch self {
        case .standard:
            false
        case .compact:
            true
        }
    }
}

// MARK: - BrowserCommandBarTextWidthMeasurer

enum BrowserCommandBarTextWidthMeasurer {
    static func width(for text: String, fontSize: CGFloat) -> CGFloat {
        let measuredText = text.isEmpty ? BrowserStrings.commandBarPlaceholder : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]

        return ceil((measuredText as NSString).size(withAttributes: attributes).width)
    }
}

// MARK: - BrowserCommandBarFaviconCandidate

struct BrowserCommandBarFaviconCandidate: Equatable {
    // MARK: Internal

    let pageURLString: String
    let faviconURL: URL?

    init(tab: BrowserChromeModel.Tab) {
        self.pageURLString = tab.urlString
        self.faviconURL = tab.faviconURL
    }

    // MARK: Private

    private static func matchesPageURL(_ lhs: String, _ rhs: String) -> Bool {
        normalizedPageURLString(lhs) == normalizedPageURLString(rhs)
    }

    private static func normalizedPageURLString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path == "/" {
            components.path = ""
        }

        return components.url?.absoluteString ?? urlString
    }

    func faviconURL(for suggestion: BrowserCommandSuggestion?) -> URL? {
        guard
            let suggestion,
            suggestion.kind == .url,
            Self.matchesPageURL(suggestion.resolvedURLString, pageURLString)
        else {
            return nil
        }

        return faviconURL
    }
}

// MARK: - BrowserCommandBarLayout

struct BrowserCommandBarLayout {
    // MARK: Internal

    let availableSize: CGSize
    let style: BrowserCommandBarOverlayStyle
    let displayText: String
    let suggestionCount: Int
    /// Room for a site search chip or offer beside the text.
    var extraWidth: CGFloat = 0

    var panelWidth: CGFloat {
        switch style {
        case .standard:
            return min(
                BrowserChromeLayout.commandBarWidth,
                max(availableSize.width - BrowserChromeLayout.sidebarOuterPadding * 2, 0),
            )
        case .compact(let anchor, let sidebarWidth, let matchesAnchorWidth):
            let padding = BrowserChromeLayout.compactCommandBarHorizontalViewportPadding
            let viewportMaximum = isTrailingAnchor
                ? max((anchor?.maxX ?? availableSize.width) - padding, 0)
                : max(availableSize.width - leadingOriginX - padding, 0)
            if matchesAnchorWidth, let anchor {
                return min(max(anchor.width, 0), viewportMaximum)
            }
            let maximum = min(
                max(availableSize.width * BrowserChromeLayout.compactCommandBarMaximumWindowFraction, 0),
                viewportMaximum,
            )
            let minimum = min(
                max(
                    sidebarWidth,
                    BrowserChromeModel.minSidebarWidth * BrowserChromeLayout.compactCommandBarMinimumSidebarMultiplier,
                ),
                maximum,
            )
            let measured = BrowserCommandBarTextWidthMeasurer.width(for: displayText, fontSize: style.fontSize)
                + BrowserChromeLayout.compactCommandBarTextWidthBuffer + extraWidth
            return max(min(max(measured, minimum), maximum), 0)
        }
    }

    /// The anchor sits in the right half of the window, as with a sidebar on the right.
    var isTrailingAnchor: Bool {
        guard case .compact(let anchor?, _, _) = style else { return false }
        return anchor.midX > availableSize.width / 2
    }

    var leadingOriginX: CGFloat {
        guard case .compact(let anchor, _, _) = style else { return 0 }
        return max(anchor?.minX ?? BrowserChromeLayout.sidebarOuterPadding, BrowserChromeLayout.sidebarOuterPadding)
    }

    var origin: CGPoint {
        switch style {
        case .standard:
            return CGPoint(
                x: max((availableSize.width - min(
                    BrowserChromeLayout.commandBarWidth,
                    max(availableSize.width - BrowserChromeLayout.sidebarOuterPadding * 2, 0),
                )) / 2, 0),
                y: standardTopInset,
            )
        case .compact(let anchor, _, _):
            // A sidebar on the right anchors the bar at its trailing edge.
            let x = isTrailingAnchor
                ? max((anchor?.maxX ?? availableSize.width) - panelWidth, BrowserChromeLayout.sidebarOuterPadding)
                : leadingOriginX
            let y: CGFloat =
                if let anchor {
                    max(
                        availableSize.height - anchor.maxY + BrowserChromeLayout.compactCommandBarTopGap,
                        BrowserChromeLayout.sidebarOuterPadding,
                    )
                } else {
                    BrowserChromeLayout.sidebarOuterPadding + BrowserChromeLayout.chromeButtonSize
                        + BrowserChromeLayout.sidebarSectionSpacing + BrowserChromeLayout.compactCommandBarTopGap
                }
            return CGPoint(x: x, y: y)
        }
    }

    var inputHeight: CGFloat { max(style.fieldHeight, 28 + BrowserChromeLayout.commandBarRowVerticalPadding * 2) }
    var visibleSuggestionCount: Int { min(suggestionCount, BrowserCommandBarModel.maximumVisibleSuggestions) }
    var suggestionViewportHeight: CGFloat {
        guard visibleSuggestionCount > 0 else { return 0 }
        return CGFloat(visibleSuggestionCount) * BrowserChromeLayout.commandBarSuggestionRowHeight
            + CGFloat(max(visibleSuggestionCount - 1, 0)) * BrowserChromeLayout.commandBarSuggestionSpacing
            + BrowserChromeLayout.commandBarSuggestionVerticalInset * 2
            + (suggestionCount > visibleSuggestionCount ? BrowserChromeLayout.commandBarSuggestionViewportAllowance : 0)
    }

    var panelHeight: CGFloat {
        BrowserChromeLayout.commandBarOuterPadding + inputHeight
            + (suggestionCount > 0 ? 1 + suggestionViewportHeight : BrowserChromeLayout.commandBarOuterPadding)
    }

    var panelFrame: CGRect { CGRect(origin: origin, size: CGSize(width: panelWidth, height: panelHeight)) }

    // MARK: Private

    private var standardTopInset: CGFloat {
        let count = BrowserCommandBarModel.maximumVisibleSuggestions
        let estimated = BrowserChromeLayout.commandBarOuterPadding + style.fieldHeight + 1
            + CGFloat(count) * BrowserChromeLayout.commandBarSuggestionRowHeight
            + CGFloat(count - 1) * BrowserChromeLayout.commandBarSuggestionSpacing
            + BrowserChromeLayout.commandBarSuggestionVerticalInset * 2
            + BrowserChromeLayout.commandBarSuggestionViewportAllowance
        let centered = (availableSize.height - estimated) / 2
        let maximum = max(
            availableSize.height - estimated - BrowserChromeLayout.commandBarTopInsetMinimum,
            BrowserChromeLayout.sidebarOuterPadding,
        )
        return min(max(centered, BrowserChromeLayout.commandBarTopInsetMinimum), maximum)
    }
}
