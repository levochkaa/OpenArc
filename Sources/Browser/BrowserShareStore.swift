// BrowserShareStore.swift

import Foundation

// MARK: - BrowserShareLinkEvents

/// What the engine posts when a page opens `openarc://share/<id>`, which the
/// app takes instead of the page. Posted on the main thread.
@objc final class BrowserShareLinkEvents: NSObject {
    @objc static let open = Notification.Name("BrowserShareLinkOpen")
    /// The link's address in `open`'s user info.
    @objc static let urlKey = "url"
}

// MARK: - BrowserShareStore

/// The signed-in account's shared links: publishing, the list Settings shows,
/// and removing. One per profile, like the account.
@MainActor final class BrowserShareStore: ObservableObject {
    // MARK: Internal

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Most recently shared first.
    @Published private(set) var links = [BrowserSharedLink]()
    @Published private(set) var loadState = LoadState.idle

    // MARK: Private

    private let transport: (any BrowserShareTransport)?
    private let session: @MainActor () -> BrowserAuthSession?

    /// Whether a link can be published now: a server and a signed-in account.
    var canPublish: Bool { transport != nil && session() != nil }
    /// Whether shared links can be read, signed in or not.
    var canRead: Bool { transport != nil }

    /// `session` is the profile's signed-in account, nil while signed out.
    init(transport: (any BrowserShareTransport)?, session: @escaping @MainActor () -> BrowserAuthSession?) {
        self.transport = transport
        self.session = session
    }

    static func message(for error: Error) -> String {
        switch error as? BrowserShareError {
        case .signedOut: BrowserStrings.shareSignedOut
        case .notFound: BrowserStrings.shareNotFound
        case .rejected(let message),
             .tooManyRequests(let message):
            message ?? BrowserStrings.shareFailedDetail
        case .server(_, let message): message ?? BrowserStrings.shareFailedDetail
        case nil: (error as? LocalizedError)?.errorDescription ?? BrowserStrings.shareFailedDetail
        }
    }

    /// The link this Space or folder already has, if it was shared before.
    func link(forSourceID sourceID: String, kind: BrowserShareKind) -> BrowserSharedLink? {
        links.first { $0.sourceID == sourceID && $0.kind == kind }
    }

    /// Publishes, or updates the link the same Space, folder or quote has.
    func publish(_ request: BrowserShareRequest) async throws -> BrowserSharedLink {
        guard let transport, let session = session() else { throw BrowserShareError.signedOut }
        let link = try await transport.publishShare(request, authSession: session)
        links.removeAll { $0.id == link.id }
        links.insert(link, at: 0)
        return link
    }

    func refresh() async {
        guard let transport, let session = session() else {
            reset()
            return
        }
        loadState = .loading
        do {
            let fetched = try await transport.listShares(authSession: session)
            // A sign-out or another account while loading drops the answer.
            guard self.session()?.userID == session.userID else { return }
            links = fetched
            loadState = .loaded
        } catch {
            loadState = .failed(Self.message(for: error))
        }
    }

    /// Stops sharing: the link stops working for everyone.
    func remove(_ link: BrowserSharedLink) async throws {
        guard let transport, let session = session() else { throw BrowserShareError.signedOut }
        do {
            try await transport.deleteShare(id: link.id, authSession: session)
        } catch BrowserShareError.notFound {
            // Already gone, as from another Mac.
        }
        links.removeAll { $0.id == link.id }
    }

    func content(id: String) async throws -> BrowserSharedContent {
        guard let transport else { throw BrowserShareError.notFound }
        return try await transport.readShare(id: id)
    }

    /// Forgets the list, as after signing out.
    func reset() {
        guard !links.isEmpty || loadState != .idle else { return }
        links = []
        loadState = .idle
    }
}
