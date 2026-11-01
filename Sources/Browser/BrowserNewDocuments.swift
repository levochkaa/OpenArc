// BrowserNewDocuments.swift

import Foundation

// MARK: - BrowserNewDocument

/// A page that starts a new document, offered in the command bar.
struct BrowserNewDocument: Equatable {
    static let googleDoc = Self(title: BrowserStrings.newDocumentGoogleDoc, urlString: "https://doc.new")
    static let wordDocument = Self(title: BrowserStrings.newDocumentWord, urlString: "https://word.new")
    static let notionPage = Self(title: BrowserStrings.newDocumentNotion, urlString: "https://app.notion.com/new")

    static let others = [
        Self(title: BrowserStrings.newDocumentGoogleSheet, urlString: "https://sheet.new"),
        Self(title: BrowserStrings.newDocumentGoogleSlides, urlString: "https://slide.new"),
        Self(title: BrowserStrings.newDocumentFigma, urlString: "https://figma.new"),
        Self(title: BrowserStrings.newDocumentFigJam, urlString: "https://figjam.new"),
        Self(title: BrowserStrings.newDocumentMeeting, urlString: "https://meet.new"),
    ]

    let title: String
    let urlString: String

    /// The documents to offer for a query, the preferred kind first. Short queries match
    /// nothing, so ordinary typing keeps its usual suggestions.
    static func matching(_ query: String, app: BrowserNewDocumentsApp) -> [Self] {
        let query = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else { return [] }
        let preferred = app.document
        let writing = [googleDoc, wordDocument, notionPage].filter { $0 != preferred }
        return ([preferred] + writing + others).filter { $0.title.lowercased().contains(query) }
    }
}

// MARK: - BrowserNewDocumentsApp

/// The app new documents open in first.
enum BrowserNewDocumentsApp: String, CaseIterable {
    case googleDocs
    case word
    case notion

    // MARK: Internal

    var title: String {
        switch self {
        case .googleDocs: BrowserStrings.newDocumentsAppGoogleDocs
        case .word: BrowserStrings.newDocumentsAppWord
        case .notion: BrowserStrings.newDocumentsAppNotion
        }
    }

    var document: BrowserNewDocument {
        switch self {
        case .googleDocs: .googleDoc
        case .word: .wordDocument
        case .notion: .notionPage
        }
    }
}

// MARK: - BrowserSmallWindowLifetime

/// How long an unused small window stays open.
enum BrowserSmallWindowLifetime: Double, CaseIterable {
    case oneHour = 3600
    case twelveHours = 43200
    case oneDay = 86400
    case never = 0

    // MARK: Internal

    var title: String {
        switch self {
        case .oneHour: BrowserStrings.settingsSmallWindowLifetimeOneHour
        case .twelveHours: BrowserStrings.settingsSmallWindowLifetimeTwelveHours
        case .oneDay: BrowserStrings.settingsSmallWindowLifetimeOneDay
        case .never: BrowserStrings.settingsSmallWindowLifetimeNever
        }
    }
}
