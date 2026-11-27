// BrowserSearchEngine.swift

import Foundation

// MARK: - BrowserSearchEngine

enum BrowserSearchEngine: String, CaseIterable, Codable, Identifiable {
    case google
    case microsoftBing
    case yahoo
    case duckDuckGo
    case ecosia
    case brave
    case qwant
    case yandex
    case baidu

    // MARK: Internal

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .google:
            BrowserStrings.settingsSearchEngineGoogle
        case .microsoftBing:
            BrowserStrings.settingsSearchEngineMicrosoftBing
        case .yahoo:
            BrowserStrings.settingsSearchEngineYahoo
        case .duckDuckGo:
            BrowserStrings.settingsSearchEngineDuckDuckGo
        case .ecosia:
            BrowserStrings.settingsSearchEngineEcosia
        case .brave:
            BrowserStrings.settingsSearchEngineBrave
        case .qwant:
            BrowserStrings.settingsSearchEngineQwant
        case .yandex:
            BrowserStrings.settingsSearchEngineYandex
        case .baidu:
            BrowserStrings.settingsSearchEngineBaidu
        }
    }

    /// The engine as the Rust core names it.
    var coreEngine: CoreSearchEngine {
        switch self {
        case .google: .google
        case .microsoftBing: .microsoftBing
        case .yahoo: .yahoo
        case .duckDuckGo: .duckDuckGo
        case .ecosia: .ecosia
        case .brave: .brave
        case .qwant: .qwant
        case .yandex: .yandex
        case .baidu: .baidu
        }
    }

    func searchURLString(for query: String) -> String {
        coreSearchUrl(engine: coreEngine, query: query)
    }
}
