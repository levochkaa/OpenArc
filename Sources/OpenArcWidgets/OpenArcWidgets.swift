// OpenArcWidgets.swift

import SwiftUI
import WidgetKit

// MARK: - OpenArcWidgets

/// The Home Screen widgets. WidgetKit draws widgets only from SwiftUI views.
@main
struct OpenArcWidgets: WidgetBundle {
    var body: some Widget {
        OpenArcSearchWidget()
    }
}

// MARK: - OpenArcSearchWidget

/// Search, Voice Search and New Tab, one tap from the Home Screen.
struct OpenArcSearchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "browser.search", provider: Provider()) { _ in
            OpenArcSearchWidgetView()
                .containerBackground(for: .widget) { Color(uiColor: .secondarySystemBackground) }
        }
        .configurationDisplayName(String(localized: "Search"))
        .description(String(localized: "Search, search by voice or open a new tab."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Provider

/// The widget shows the same thing all the time.
struct Provider: TimelineProvider {
    func placeholder(in _: Context) -> SimpleEntry { SimpleEntry(date: .now) }

    func getSnapshot(in _: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: .now))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }
}

// MARK: - SimpleEntry

struct SimpleEntry: TimelineEntry {
    let date: Date
}

// MARK: - OpenArcSearchWidgetView

struct OpenArcSearchWidgetView: View {
    // MARK: Internal

    var body: some View {
        switch family {
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Private

    @Environment(\.widgetFamily) private var family

    private var small: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                mark
                Link(destination: BrowserMobileAppLink.search.url) {
                    field(showsMicrophone: false)
                }
            }
            HStack(spacing: 10) {
                Link(destination: BrowserMobileAppLink.voiceSearch.url) {
                    roundButton(symbol: "mic.fill", label: String(localized: "Voice Search"))
                }
                Link(destination: BrowserMobileAppLink.newTab.url) {
                    roundButton(symbol: "plus", label: String(localized: "New Tab"))
                }
            }
        }
    }

    private var medium: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                mark
                Link(destination: BrowserMobileAppLink.search.url) {
                    field(showsMicrophone: true)
                }
            }
            HStack(spacing: 10) {
                Link(destination: BrowserMobileAppLink.voiceSearch.url) {
                    pill(symbol: "mic.fill", title: String(localized: "Voice Search"))
                }
                Link(destination: BrowserMobileAppLink.newTab.url) {
                    pill(symbol: "plus", title: String(localized: "New Tab"))
                }
            }
        }
    }

    private var mark: some View {
        Image("AppMark")
            .resizable()
            .widgetAccentedRenderingMode(.desaturated)
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }

    private func field(showsMicrophone: Bool) -> some View {
        HStack {
            Text(String(localized: "Search"))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if showsMicrophone {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }

    private func roundButton(symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            .accessibilityLabel(label)
    }

    private func pill(symbol: String, title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }
}
