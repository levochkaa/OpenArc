// BrowserWebKitDownloadsTests.swift

import Foundation
import Network
import Testing
import WebKit

// MARK: - BrowserWebKitDownloadsTests

@Suite(.serialized) @MainActor struct BrowserWebKitDownloadsTests {
    @Test func nativeDownloadsPreserveTheSourceDocumentAndAuthenticatedPOSTContext() async throws {
        try await withDownloadWebKit { f in
            let before = try f.store.loadSnapshotStrict()
            let selected = f.workspace.selectedTabID
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            let history = view.backForwardList.backList.map(\.url)
            let documentIdentity = UUID().uuidString
            _ = try await view.evaluateJavaScript("window.downloadTestDocumentIdentity = '\(documentIdentity)'")
            f.observedURLs.removeAll()
            var files = Set<URL>()
            for (index, element) in ["attribute", "attachment", "redirect", "unknown", "post"].enumerated() {
                _ = try await view.evaluateJavaScript("document.getElementById('\(element)').click()")
                try await downloadWait {
                    f.downloads.entries.count == index + 1 && f.downloads.entries.allSatisfy { $0.status == .completed }
                }
                let entry = try #require(f.downloads.entries.first)
                let url = try await f.downloads.exportURL(id: entry.id)
                let isUniqueFile = files.insert(url).inserted
                #expect(isUniqueFile)
                let bytes = try Data(contentsOf: url)
                #expect(bytes == (element == "post" ? DownloadHTTPFixture.postBytes : DownloadHTTPFixture.bytes))
                if element == "unknown" {
                    #expect(!entry.filename.isEmpty && !entry.filename.contains("/"))
                } else {
                    #expect(entry.filename == "same.bin")
                }
                #expect(entry.receivedBytes == Int64(bytes.count))
                #expect(f.workspace.selectedTabID == selected && f.workspace.selectedTab?.runtimeID == runtime)
                #expect(f.workspace.selectedTab?.urlString == f.sourceURL.absoluteString)
                #expect(f.workspace.selectedTab?.title == "Download source" && f.workspace.selectedTab?.state
                    .error == nil)
                let immediateViewURL = view.url
                let immediateHistoryURL = view.backForwardList.currentItem?.url
                let documentValue = try await view.evaluateJavaScript("""
                ({ href: location.href, title: document.title,
                   identity: window.downloadTestDocumentIdentity,
                   hasSourceForm: document.getElementById('post') !== null })
                """)
                let document = try #require(documentValue as? [String: Any])
                let diagnostic = "element=\(element), immediateWKURL=\(String(describing: immediateViewURL)), "
                    + "historyURL=\(String(describing: immediateHistoryURL)), afterJSWKURL=\(String(describing: view.url)), "
                    + "document=\(document)"
                #expect(f.engine.webView(for: runtime) === view)
                #expect(immediateHistoryURL == f.sourceURL, Comment(rawValue: diagnostic))
                #expect(document["href"] as? String == f.sourceURL.absoluteString, Comment(rawValue: diagnostic))
                #expect(document["title"] as? String == "Download source", Comment(rawValue: diagnostic))
                #expect(document["identity"] as? String == documentIdentity, Comment(rawValue: diagnostic))
                #expect(document["hasSourceForm"] as? Bool == true, Comment(rawValue: diagnostic))
                // WKDownload may finish before the converted provisional
                // navigation rolls its URL accessor back. The committed DOM,
                // current history item and browser state above never changed.
                try await downloadWait { view.url == f.sourceURL }
                #expect(view.backForwardList.backList.map(\.url) == history)
                #expect(try f.store.loadSnapshotStrict() == before)
            }
            #expect(f.observedURLs.allSatisfy { $0 == f.sourceURL.absoluteString })
            let post = try #require(f.server.requests.first { $0.path == "/post" })
            #expect(post.method == "POST" && post.body == Data("value=cookie+and+post".utf8))
            #expect(post.cookie.contains("download-token=kept"))
            #expect(f.server.requests.count(where: { $0.path == "/post" }) == 1)
            #expect(f.server.requests.count(where: { $0.path == "/inline" }) == 1)
            #expect(f.server.requests.count(where: { $0.path == "/attachment" }) == 2)
            let reopened = BrowserMobileDownloads(directory: f.downloadDirectory)
            await reopened.load()
            #expect(Set(reopened.entries.map(\.id)) == Set(f.downloads.entries.map(\.id)))
            for entry in reopened.entries {
                let file = try await reopened.exportURL(id: entry.id)
                #expect(FileManager.default.fileExists(atPath: file.path))
                #expect(entry.status == .completed)
            }
        }
    }

    @Test func typedAttachmentRestoresFinalDurableSourceAndTheSameViewCanStillNavigate() async throws {
        try await withDownloadWebKit { f in
            let before = try f.store.loadSnapshotStrict()
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            let history = view.backForwardList.backList.map(\.url)
            try f.workspace.submit(f.server.url("/attachment").absoluteString)
            try await downloadWait { f.downloads.entries.first?.status == .completed }
            // Address submission records explicit intent before the HTTP response.
            // Conversion must repair the final logical/durable URL, without
            // replacing the source view or adding the attachment to its history.
            #expect(f.workspace.selectedTab?.urlString == f.sourceURL.absoluteString)
            #expect(f.workspace.selectedTab?.title == "Download source" && f.workspace.selectedTab?.state.error == nil)
            #expect(try f.store.loadSnapshotStrict() == before)
            #expect(f.engine.webView(for: runtime) === view && view.backForwardList.backList.map(\.url) == history)
            f.workspace.goBack()
            try await downloadWait {
                f.workspace.selectedTab?.title == "First" && f.workspace.selectedTab?.state.isLoading == false
            }
            f.workspace.goForward()
            try await downloadWait {
                f.workspace.selectedTab?.title == "Download source" && f.workspace.selectedTab?.state
                    .isLoading == false
            }
            _ = try await view.evaluateJavaScript("location.hash = 'after-download'")
            try await downloadWait {
                f.workspace.selectedTab?.urlString == f.sourceURL.absoluteString + "#after-download"
            }
            #expect(f.workspace.selectedTab?.state.error == nil)
        }
    }

    @Test(arguments: ["blob", "data"])
    func generatedFileDownloadsKeepExactBytesWithoutPersistingTheirPayloadOrToken(scheme: String) async throws {
        try await withDownloadWebKit { f in
            let before = try f.store.loadSnapshotStrict()
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            let expected = Data([0, 1, 10, 13, 128, 255])
            let target = scheme == "blob"
                ? "URL.createObjectURL(new Blob([new Uint8Array([0,1,10,13,128,255])], {type:'application/octet-stream'}))"
                : "'data:application/octet-stream;base64,\(expected.base64EncodedString())'"
            _ = try await view.evaluateJavaScript("""
            (() => {
                const link = document.createElement('a');
                link.download = 'generated.bin';
                link.href = \(target);
                document.body.appendChild(link);
                link.click();
            })()
            """)
            try await downloadWait { f.downloads.entries.first?.status == .completed }
            let entry = try #require(f.downloads.entries.first)
            let file = try await f.downloads.exportURL(id: entry.id)
            #expect(try Data(contentsOf: file) == expected)
            #expect(entry.filename == "generated.bin" && entry.sourceURL == f.sourceURL)
            #expect(f.workspace.selectedTab?.runtimeID == runtime && f.workspace.selectedTab?.urlString == f.sourceURL
                .absoluteString)
            #expect(f.workspace.selectedTab?.state.error == nil)
            #expect(try f.store.loadSnapshotStrict() == before)
            let manifestData = try Data(contentsOf: f.downloadDirectory.appendingPathComponent("downloads.json"))
            let manifest = try #require(String(data: manifestData, encoding: .utf8))
            #expect(!manifest.contains("data:") && !manifest.contains("blob:"))
            #expect(!manifest.contains(expected.base64EncodedString()))
        }
    }

    @Test(arguments: [false, true])
    func clearCompletedPreservesDownloadsThatFinishAfterCapture(finishBeforeClear: Bool) async throws {
        try await withDownloadWebKit { f in
            let before = try f.store.loadSnapshotStrict()
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            let history = view.backForwardList.backList.map(\.url)
            for (index, element) in ["attribute", "attachment"].enumerated() {
                _ = try await view.evaluateJavaScript("document.getElementById('\(element)').click()")
                try await downloadWait {
                    f.downloads.entries.count == index + 1 && f.downloads.entries.allSatisfy { $0.status == .completed }
                }
            }
            let capturedIDs = Set(f.downloads.entries.map(\.id))
            var oldFiles = [URL]()
            for id in capturedIDs {
                try await oldFiles.append(f.downloads.exportURL(id: id))
            }
            _ = try await view.evaluateJavaScript("document.getElementById('slow').click()")
            try await downloadWait {
                f.downloads.entries.contains { $0.status == .downloading && $0.receivedBytes > 0 }
            }
            let continuing = try #require(f.downloads.entries.first { !capturedIDs.contains($0.id) })
            let scope = try #require(f.downloads.captureCompletedClear())
            #expect(scope.ids == capturedIDs && scope.count == 2)
            if finishBeforeClear {
                f.server.finishSlowResponses()
                try await downloadWait { f.downloads.entries.first { $0.id == continuing.id }?.status == .completed }
            }
            #expect(await f.downloads.clearCompleted(scope) == .removed)
            #expect(f.downloads.entries.map(\.id) == [continuing.id])
            #expect(oldFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            if !finishBeforeClear {
                #expect(f.downloads.entries.first?.status == .downloading)
                f.server.finishSlowResponses()
                try await downloadWait { f.downloads.entries.first?.status == .completed }
            }
            let saved = try await f.downloads.exportURL(id: continuing.id)
            #expect(try Data(contentsOf: saved) == DownloadHTTPFixture.slowBytes)
            #expect(await f.downloads.clearCompleted(scope) == .removed)
            #expect(f.downloads.entries.map(\.id) == [continuing.id])
            #expect(f.engine.webView(for: runtime) === view)
            #expect(view.backForwardList.backList.map(\.url) == history)
            #expect(try await view.evaluateJavaScript("location.href") as? String == f.sourceURL.absoluteString)
            #expect(try f.store.loadSnapshotStrict() == before)
            let reopened = BrowserMobileDownloads(directory: f.downloadDirectory)
            await reopened.load()
            #expect(reopened.entries.map(\.id) == [continuing.id])
            #expect(try await Data(contentsOf: reopened.exportURL(id: continuing.id)) == DownloadHTTPFixture.slowBytes)
        }
    }

    @Test(arguments: [false, true])
    func profileTransferSurvivesTheSourceTabOrEngineClosing(shutdown: Bool) async throws {
        try await withDownloadWebKit { f in
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            _ = try await view.evaluateJavaScript("document.getElementById('slow').click()")
            try await downloadWait { f.downloads.entries.first?.receivedBytes ?? 0 > 0 }
            let entry = try #require(f.downloads.entries.first)
            #expect(entry.status == .downloading && entry.totalBytes == Int64(DownloadHTTPFixture.slowBytes.count))
            if shutdown {
                f.engine.shutdown()
            } else {
                f.engine.closeTab(id: runtime)
            }
            #expect(f.engine.webView(for: runtime) == nil)
            f.server.finishSlowResponses()
            try await downloadWait { f.downloads.entries.first { $0.id == entry.id }?.status == .completed }
            let file = try await f.downloads.exportURL(id: entry.id)
            #expect(try Data(contentsOf: file) == DownloadHTTPFixture.slowBytes)
            #expect(f.downloads.entries.count == 1)
        }
    }

    @Test func cancelAndTruncatedTransferStayOutOfExportWithoutTurningThePageIntoAnError() async throws {
        try await withDownloadWebKit { f in
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            let before = try f.store.loadSnapshotStrict()
            _ = try await view.evaluateJavaScript("document.getElementById('slow').click()")
            try await downloadWait { f.downloads.entries.first?.receivedBytes ?? 0 > 0 }
            let cancelled = try #require(f.downloads.entries.first)
            f.downloads.cancel(id: cancelled.id)
            #expect(f.downloads.entries.first?.status == .cancelled)
            f.server.finishSlowResponses()
            try await assertDownloadNotExportable(f.downloads, id: cancelled.id)
            _ = try await view.evaluateJavaScript("document.getElementById('broken').click()")
            try await downloadWait { f.downloads.entries.count == 2 && f.downloads.entries.first?.status == .failed }
            let failed = try #require(f.downloads.entries.first)
            #expect(failed.error != nil)
            try await assertDownloadNotExportable(f.downloads, id: failed.id)
            #expect(f.downloads.entries.first { $0.id == cancelled.id }?.status == .cancelled)
            #expect(f.workspace.selectedTab?.urlString == f.sourceURL.absoluteString)
            #expect(f.workspace.selectedTab?.title == "Download source" && f.workspace.selectedTab?.state.error == nil)
            #expect(try f.store.loadSnapshotStrict() == before)
        }
    }

    @Test func finishedFileSurvivesManifestFailureAndCoordinatorRetryPublishesItExactlyOnce() async throws {
        try await withDownloadWebKit { f in
            let manifest = f.downloadDirectory.appendingPathComponent("downloads.json", isDirectory: true)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            let observed = DownloadStatusLog()
            let observation = f.downloads.observe {
                guard let entry = f.downloads.entries.first else { return }
                observed.values.append(entry.status)
                if entry.status == .saving {
                    // Native transfer has finished; Cancel must not discard a
                    // file awaiting durable metadata, even from an observer.
                    f.downloads.cancel(id: entry.id)
                    #expect(f.downloads.entries.first?.status == .saving)
                }
            }
            defer { f.downloads.removeObserver(observation) }
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let view = try #require(f.engine.webView(for: runtime))
            _ = try await view.evaluateJavaScript("document.getElementById('attachment').click()")
            try await downloadWait { f.downloads.entries.first?.status == .failed && f.downloads.canRetryPersistence }
            let failed = try #require(f.downloads.entries.first)
            #expect(observed.values.contains(.saving) && !observed.values.contains(.cancelled))
            let retainedFile = f.downloadDirectory
                .appendingPathComponent(failed.id.uuidString)
                .appendingPathComponent(failed.filename)
            #expect(try Data(contentsOf: retainedFile) == DownloadHTTPFixture.bytes)
            try await assertDownloadNotExportable(f.downloads, id: failed.id)
            try FileManager.default.removeItem(at: manifest)
            await f.downloads.retryPersistence()
            #expect(f.downloads.entries.count == 1 && f.downloads.entries.first?.status == .completed)
            let exported = try await f.downloads.exportURL(id: failed.id)
            #expect(try Data(contentsOf: exported) == DownloadHTTPFixture.bytes)
            let reopened = BrowserMobileDownloads(directory: f.downloadDirectory)
            await reopened.load()
            #expect(reopened.entries.map(\.id) == [failed.id])
            let recovered = try await reopened.exportURL(id: failed.id)
            #expect(try Data(contentsOf: recovered) == DownloadHTTPFixture.bytes)
            #expect(f.server.requests.count(where: { $0.path == "/attachment" }) == 1)
            #expect(f.workspace.selectedTab?.urlString == f.sourceURL.absoluteString)
        }
    }
}

// MARK: - DownloadStatusLog

@MainActor private final class DownloadStatusLog {
    var values = [BrowserMobileDownload.Status]()
}

@MainActor private func assertDownloadNotExportable(_ downloads: BrowserMobileDownloads, id: UUID) async throws {
    do {
        _ = try await downloads.exportURL(id: id)
        Issue.record("A cancelled or failed transfer must not expose a file for export")
    } catch {
        #expect(error as? BrowserMobileDownloadError == .notCompleted)
    }
}

@MainActor private func downloadWait(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The local WebKit download did not reach the expected state")
    throw URLError(.timedOut)
}

@MainActor private func withDownloadWebKit(_ body: @MainActor (DownloadWebKitFixture) async throws
    -> Void) async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WebKitDownload-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await runDownloadWebKit(directory: directory, body: body)
}

@MainActor private func runDownloadWebKit(
    directory: URL, body: @MainActor (DownloadWebKitFixture) async throws -> Void,
) async throws {
    let f = try DownloadWebKitFixture(directory: directory)
    defer { f.stop() }
    try await f.start()
    try await body(f)
    _ = await f.workspace.shutdown()
}

// MARK: - DownloadWebKitFixture

@MainActor private final class DownloadWebKitFixture {
    // MARK: Internal

    let server: DownloadHTTPFixture
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let downloads: BrowserMobileDownloads
    let downloadDirectory: URL
    let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
    let workspace: BrowserMobileWorkspace
    let preferences: UserDefaults
    let preferencesName: String
    var observedURLs = [String]()
    private(set) var sourceURL = URL(string: "about:blank")!

    init(directory: URL) throws {
        self.downloadDirectory = directory.appendingPathComponent("Downloads")
        self.downloads = BrowserMobileDownloads(directory: downloadDirectory)
        self.server = try DownloadHTTPFixture()
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        let seed = BrowserTabSessionSnapshot(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
            tabs: [.init(id: "page", urlString: "about:blank", spaceID: "space", lastActivityTimestamp: 1_800_000_000)],
        )
        try store.writeSessionBatch([.init(snapshot: seed, origin: .local(syncMove: nil))])
        self.document = try BrowserMobileProfileDocument(
            store: store, initialSnapshot: seed, downloads: downloads,
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) }, automaticArchivalCheckInterval: nil,
        )
        self.preferencesName = "Downloads." + UUID().uuidString
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        let profile = document
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: "downloads", profileLoader: { profile }, preferences: preferences,
        )
        workspace.onChange = { [weak self] in
            guard let self, let url = workspace.selectedTab?.urlString else { return }
            observedURLs.append(url)
        }
    }

    func start() async throws {
        try await server.start()
        sourceURL = try server.url("/second")
        await downloads.load()
        await workspace.restore()
        #expect(workspace.isReady && workspace.downloads === downloads)
        try workspace.submit(server.url("/first").absoluteString)
        try await downloadWait {
            workspace.selectedTab?.title == "First" && workspace.selectedTab?.state.isLoading == false
        }
        let runtime = try #require(workspace.selectedTab?.runtimeID)
        let view = try #require(engine.webView(for: runtime))
        _ = try await view.evaluateJavaScript("document.getElementById('next').click()")
        try await downloadWait {
            workspace.selectedTab?.title == "Download source" && workspace.selectedTab?.state.isLoading == false
        }
        #expect(view.backForwardList.backItem != nil)
    }

    func stop() {
        for entry in downloads.entries where entry.status == .downloading {
            downloads.cancel(id: entry.id)
        }
        workspace.onChange = nil
        engine.shutdown()
        server.stop()
        preferences.removePersistentDomain(forName: preferencesName)
    }
}

// MARK: - DownloadHTTPFixture

/// Loopback-only HTTP; transfers retain WebKit's real Cookie/POST context.
@MainActor private final class DownloadHTTPFixture {
    // MARK: Internal

    struct Request {
        let method: String
        let path: String
        let cookie: String
        let body: Data
    }

    static let bytes = Data((0..<1024).map { UInt8($0 % 251) })
    static let postBytes = Data("Authenticated POST context preserved".utf8)
    static let slowBytes = Data(repeating: 0xA7, count: 512 * 1024)

    private(set) var requests = [Request]()

    // MARK: Private

    private let listener: NWListener
    private var connections = [ObjectIdentifier: NWConnection]()
    private var slowConnections = [NWConnection]()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready: finishStarting()
                    case .failed(let error),
                         .waiting(let error): finishStarting(error: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel()
                        return
                    }
                    connections[ObjectIdentifier(connection)] = connection
                    connection.start(queue: .main)
                    receive(connection, accumulated: Data())
                }
            }
            listener.start(queue: .main)
            startTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.finishStarting(error: URLError(.timedOut))
            }
        }
    }

    func url(_ path: String) throws -> URL {
        let port = try #require(listener.port)
        return try #require(URL(string: "http://127.0.0.1:\(port.rawValue)\(path)"))
    }

    func finishSlowResponses() {
        let pending = slowConnections
        slowConnections.removeAll()
        for connection in pending {
            send(Data(Self.slowBytes.dropFirst(64 * 1024)), on: connection, close: true)
        }
    }

    func stop() {
        finishStarting(error: URLError(.cancelled))
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        slowConnections.removeAll()
        listener.cancel()
    }

    private func finishStarting(error: Error? = nil) {
        startTimeout?.cancel()
        startTimeout = nil
        let continuation = startContinuation
        startContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel()
                        return
                    }
                    var bytes = accumulated
                    if let data {
                        bytes.append(data)
                    }
                    guard error == nil, bytes.count <= 64 * 1024 else { connection.cancel()
                        return
                    }
                    guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                        if !complete {
                            receive(connection, accumulated: bytes)
                        } else {
                            connection.cancel()
                        }
                        return
                    }
                    let header = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
                    let lines = header.components(separatedBy: "\r\n")
                    let length = lines.first { $0.lowercased().hasPrefix("content-length:") }
                        .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
                        } ??
                        0
                    let body = Data(bytes[separator.upperBound...])
                    guard body.count >= length else {
                        if !complete {
                            receive(connection, accumulated: bytes)
                        } else {
                            connection.cancel()
                        }
                        return
                    }
                    let parts = (lines.first ?? "").split(separator: " ")
                    guard parts.count >= 2 else { connection.cancel()
                        return
                    }
                    let request = Request(
                        method: String(parts[0]), path: String(parts[1]),
                        cookie: lines.first { $0.lowercased().hasPrefix("cookie:") } ?? "",
                        body: Data(body.prefix(length)),
                    )
                    requests.append(request)
                    respond(to: request, on: connection)
                }
            }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        switch request.path {
        case "/first":
            response(
                Data("<title>First</title><a id='next' href='/second'>Next</a>".utf8),
                type: "text/html",
                on: connection,
            )
        case "/second":
            let html = """
            <title>Download source</title>
            <a id='attribute' href='/inline' download='same.bin'>Attribute</a>
            <a id='attachment' href='/attachment'>Attachment</a>
            <a id='redirect' href='/redirect'>Redirect</a>
            <a id='unknown' href='/unknown'>Unknown MIME</a>
            <a id='slow' href='/slow'>Slow</a><a id='broken' href='/broken'>Broken</a>
            <form method='post' action='/post'><input name='value' value='cookie and post'><button id='post'>Post</button></form>
            """
            response(
                Data(html.utf8),
                type: "text/html",
                extra: "Set-Cookie: download-token=kept; Path=/; SameSite=Lax\r\n",
                on: connection,
            )
        case "/redirect":
            send(
                Data("HTTP/1.1 302 Found\r\nLocation: /attachment\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .utf8),
                on: connection,
                close: true,
            )
        case "/inline": response(Self.bytes, type: "text/plain", on: connection)
        case "/attachment",
             "/post",
             "/unknown":
            let body = request.path == "/post" ? Self.postBytes : Self.bytes
            let type = request.path == "/unknown" ? "application/x-openarc-test-download" : "text/plain"
            let disposition = request.path == "/unknown"
                ? ""
                : "Content-Disposition: attachment; filename=\"same.bin\"\r\n"
            // Unknown MIME has no disposition; its URL supplies the fallback name.
            response(body, type: type, extra: disposition, on: connection)
        case "/slow":
            let header = downloadHeader(length: Self.slowBytes.count)
            slowConnections.append(connection)
            send(Data(header.utf8) + Data(Self.slowBytes.prefix(64 * 1024)), on: connection, close: false)
        case "/broken":
            send(Data(downloadHeader(length: 4096).utf8) + Data("truncated".utf8), on: connection, close: true)
        default: response(Data(), type: "text/plain", on: connection)
        }
    }

    private func downloadHeader(length: Int) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"same.bin\"\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
    }

    private func response(_ body: Data, type: String, extra: String = "", on connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        send(Data(header.utf8) + body, on: connection, close: true)
    }

    private func send(_ data: Data, on connection: NWConnection, close: Bool) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard close else { return }
            connection.cancel()
            Task { @MainActor [weak self] in self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        })
    }
}
