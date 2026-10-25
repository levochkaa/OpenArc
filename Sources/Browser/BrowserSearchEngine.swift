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

    func searchURLString(for query: String) -> String {
        var components = URLComponents()
        components.scheme = "https"

        switch self {
        case .google:
            components.host = "www.google.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .microsoftBing:
            components.host = "www.bing.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yahoo:
            components.host = "search.yahoo.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "p", value: query)]
        case .duckDuckGo:
            components.host = "duckduckgo.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .ecosia:
            components.host = "www.ecosia.org"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .brave:
            components.host = "search.brave.com"
            components.path = "/search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .qwant:
            components.host = "www.qwant.com"
            components.path = "/"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .yandex:
            components.host = "yandex.com"
            components.path = "/search/"
            components.queryItems = [URLQueryItem(name: "text", value: query)]
        case .baidu:
            components.host = "www.baidu.com"
            components.path = "/s"
            components.queryItems = [URLQueryItem(name: "wd", value: query)]
        }

        return components.url?.absoluteString ?? BrowserSearchEngine.google.searchURLString(for: query)
    }
}
