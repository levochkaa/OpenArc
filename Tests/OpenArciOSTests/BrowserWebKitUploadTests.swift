// BrowserWebKitUploadTests.swift

import BrowserMobileTestHost
import Foundation
import Testing
import UIKit
import WebKit

extension BrowserMobileUITests {
    @Test(arguments: [false, true])
    func defaultWebKitUploadDeliversFilesThroughItsInstalledPickerDelegate(multiple: Bool) async throws {
        try await withUploadWebKit { f in
            let view = try await f.start()
            let before = try f.durableState()
            let history = view.backForwardList.backList.map(\.url)
            let runtime = f.workspace.selectedTab?.runtimeID
            let input = multiple ? "multiple" : "single"
            let picker = try await f.openPicker(input: input, view: view)
            #expect(picker.allowsMultipleSelection == multiple)
            let names = multiple ? ["first.txt", "second.txt"] : ["sample.txt"]
            let payloads = names.enumerated()
                .map { Data("file \($0.offset)\r\nПривет\n".utf8) + Data([0, 1, 128, 255]) }
            var files = [URL]()
            for (name, bytes) in zip(names, payloads) {
                let file = f.directory.appendingPathComponent(name)
                try bytes.write(to: file)
                files.append(file)
            }
            try await uploadSelection(files, picker: picker)
            try await uploadWait {
                await (try? view.evaluateJavaScript("document.getElementById('\(input)').files.length") as? Int) ==
                    names.count
            }
            let payload = try await view.callAsyncJavaScript(
                "return await Promise.all(Array.from(document.getElementById(input).files).map(async f=>({name:f.name, bytes:Array.from(new Uint8Array(await f.arrayBuffer()))})));",
                arguments: ["input": input], in: nil, contentWorld: .page,
            )
            let result = try #require(payload as? [[String: Any]])
            #expect(result.compactMap { $0["name"] as? String } == names)
            #expect(result.compactMap { $0["bytes"] as? [UInt8] } == payloads.map { Array($0) })
            #expect(view.uiDelegate === f.engine)
            #expect(view.navigationDelegate === f.engine)
            #expect(f.workspace.selectedTab?.runtimeID == runtime)
            #expect(f.workspace.selectedTab?.id == "a")
            #expect(try await view.evaluateJavaScript("location.href") as? String == f.server
                .url("/source")
                .absoluteString)
            #expect(view.backForwardList.backList.map(\.url) == history)
            let after = try f.durableState()
            #expect(after.0 == before.0 && after.1 == before.1)
            _ = try await view.evaluateJavaScript("document.getElementById('\(input)form').requestSubmit()")
            try await uploadWait {
                f.workspace.selectedTab?.title == "Upload received" && f.workspace.selectedTab?.state
                    .isLoading == false
            }
            let posts = f.server.requests.filter { $0.method == "POST" }
            try #require(posts.count == 1)
            let request = posts[0]
            #expect(request.path == "/submit")
            #expect(request.headers["content-type"]?.hasPrefix("multipart/form-data; boundary=") == true)
            #expect(request.headers["cookie"]?.contains("upload-token=kept") == true)
            let parts = try request.multipartParts()
            try #require(parts.count == names.count + 1)
            for (index, name) in names.enumerated() {
                #expect(parts[index]
                    .headers["content-disposition"] == "form-data; name=\"files\"; filename=\"\(name)\"")
                #expect(parts[index].headers["content-type"] == "text/plain")
                #expect(parts[index].body == payloads[index])
            }
            #expect(parts.last?.headers["content-disposition"] == "form-data; name=\"token\"")
            #expect(parts.last?.body == Data("upload-fixture".utf8))
            #expect(f.server.parseErrors.isEmpty)
        }
    }

    @Test func defaultWebKitUploadCancelCallbackLeavesInputEmptyAndCanReopen() async throws {
        try await withUploadWebKit { f in
            let view = try await f.start()
            let before = try f.durableState()
            let picker = try await f.openPicker(input: "single", view: view)
            let delegate = try #require(picker.delegate)
            let cancel = try #require(delegate.documentPickerWasCancelled)
            cancel(picker)
            await uploadDismiss(picker)
            #expect(try await view.evaluateJavaScript("document.getElementById('single').files.length") as? Int == 0)
            #expect(try await view.evaluateJavaScript("window.selectionChanges.single") as? Int == 0)
            let second = try await f.openPicker(input: "single", view: view)
            #expect(second !== picker)
            let file = f.directory.appendingPathComponent("after-cancel.txt")
            try Data("second picker".utf8).write(to: file)
            try await uploadSelection([file], picker: second)
            try await uploadWait {
                try await view.evaluateJavaScript("document.getElementById('single').files.length") as? Int == 1
            }
            #expect(try await view.evaluateJavaScript("window.selectionChanges.single") as? Int == 1)
            #expect(!f.server.requests.contains { $0.method == "POST" })
            let after = try f.durableState()
            #expect(after.0 == before.0 && after.1 == before.1)
        }
    }

    @Test(arguments: ["switch", "navigate", "close", "inactive", "disconnect", "shutdown"])
    func defaultWebKitUploadLateSelectionDoesNotCrossDocuments(transition: String) async throws {
        try await withUploadWebKit { f in
            let source = try await f.start()
            let other = try await f.loadSource(tabID: "b")
            f.workspace.selectTab(id: "a")
            let runtime = try #require(f.workspace.selectedTab?.runtimeID)
            let picker = try await f.openPicker(input: "single", view: source)
            switch transition {
            case "switch": f.workspace.selectTab(id: "b")
            case "navigate":
                try f.workspace.submit(f.server.url("/next").absoluteString)
                try await uploadWait {
                    f.workspace.selectedTab?.title == "Upload next" && f.workspace.selectedTab?.state
                        .isLoading == false
                }
                _ = try await f.loadSource(tabID: "a")
            case "close":
                f.workspace.closeTab(id: "a")
                f.workspace.selectTab(id: "b")
            case "inactive":
                f.workspace.setActivityActive(false)
                f.workspace.setJavaScriptDialogPresentationActive(false)
                f.workspace.setSyncActive(false)
            case "disconnect":
                f.workspace.setSceneAttached(false)
                f.workspace.setJavaScriptDialogPresentationActive(false)
                f.workspace.setSyncActive(false)
            case "shutdown": #expect(await f.workspace.shutdown())
            default: Issue.record("Unknown transition")
            }
            let before = try f.durableState()
            let selectedID = f.workspace.selectedTab?.id
            let file = f.directory.appendingPathComponent("late.txt")
            try Data("late selection".utf8).write(to: file)
            // Never retain WebKit's delegate across a lifecycle transition.
            // A cleared delegate means WebKit already ended this request.
            let hadDelegate = picker.delegate != nil
            if hadDelegate {
                try await uploadSelection([file], picker: picker)
            } else {
                await uploadDismiss(picker)
            }
            if hadDelegate, ["switch", "inactive", "disconnect"].contains(transition) {
                // File coordination is asynchronous. Observe actual completion
                // in the surviving source before checking the other document.
                try await uploadWait {
                    try await source.evaluateJavaScript("document.getElementById('single').files.length") as? Int == 1
                }
            }
            // Invalidated requests have no public completion acknowledgement.
            // Repeated observation is bounded evidence, not an IPC drain fence.
            let observationEnd = ContinuousClock.now.advanced(by: .seconds(1))
            repeat {
                #expect(try await other
                    .evaluateJavaScript("document.getElementById('single').files.length") as? Int == 0)
                if transition == "navigate" {
                    #expect(try await source
                        .evaluateJavaScript("document.getElementById('single').files.length") as? Int == 0)
                }
                try await Task.sleep(for: .milliseconds(40))
            } while ContinuousClock.now < observationEnd
            #expect(try await other.evaluateJavaScript("document.getElementById('single').files.length") as? Int == 0)
            #expect(try await other.evaluateJavaScript("window.selectionChanges.single") as? Int == 0)
            if transition == "navigate" {
                #expect(try await source
                    .evaluateJavaScript("document.getElementById('single').files.length") as? Int == 0)
                #expect(try await source.evaluateJavaScript("window.selectionChanges.single") as? Int == 0)
            }
            if transition == "close" || transition == "shutdown" {
                #expect(f.engine.webView(for: runtime) == nil)
            }
            let after = try f.durableState()
            #expect(after.0 == before.0 && after.1 == before.1)
            #expect(f.workspace.selectedTab?.id == selectedID)
            #expect(!f.server.requests.contains { $0.method == "POST" })
            #expect(f.server.parseErrors.isEmpty)
        }
    }
}

// MARK: - UploadWebKitFixture

@MainActor private final class UploadWebKitFixture {
    // MARK: Internal

    let directory: URL
    let server: UploadHTTPFixture
    let owner = BrowserSyncOwner(baseURL: URL(string: "https://sync.example")!, userID: "upload-owner")
    let store: BrowserSQLiteSessionStore
    let document: BrowserMobileProfileDocument
    let preferencesName = "MobileUpload." + UUID().uuidString
    let preferences: UserDefaults
    let engine = BrowserWebKitEngine(dataStore: .nonPersistent())
    let workspace: BrowserMobileWorkspace
    let root: BrowserMobileViewController
    let window: UIWindow

    init(directory: URL) throws {
        self.directory = directory
        self.server = try UploadHTTPFixture()
        self.store = try BrowserSQLiteSessionStore(databaseURL: directory.appendingPathComponent("Profile.sqlite"))
        let snapshot = BrowserTabSessionSnapshot(
            spaces: [.init(id: "space", title: "Space", systemImageName: "globe")],
            tabs: ["a", "b"].map {
                .init(id: $0, urlString: "about:blank", spaceID: "space", lastActivityTimestamp: 1_800_000_000)
            },
        )
        try store.writeSessionBatch([.init(snapshot: snapshot, origin: .local(syncMove: nil))])
        try store.bindSyncOwner(owner)
        self.document = try BrowserMobileProfileDocument(
            store: store, initialSnapshot: snapshot,
            dateProvider: { Date(timeIntervalSince1970: 1_800_000_000) }, automaticArchivalCheckInterval: nil,
        )
        self.preferences = try #require(UserDefaults(suiteName: preferencesName))
        let document = document
        self.workspace = BrowserMobileWorkspace(
            engine: engine, sceneID: UUID().uuidString, profileLoader: { document }, preferences: preferences,
        )
        self.root = BrowserMobileViewController(workspace: workspace, contentView: engine.hostView)
        self.window = try UIWindow(windowScene: #require(BrowserMobileTestScene.windowScene))
    }

    func start() async throws -> WKWebView {
        try await server.start()
        await workspace.restore()
        try #require(workspace.isReady)
        workspace.setSceneAttached(true)
        workspace.setActivityActive(true)
        workspace.setJavaScriptDialogPresentationActive(true)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        root.view.frame = window.bounds
        root.view.layoutIfNeeded()
        return try await loadSource(tabID: "a")
    }

    func loadSource(tabID: String) async throws -> WKWebView {
        workspace.selectTab(id: tabID)
        try workspace.submit(server.url("/source").absoluteString)
        try await uploadWait {
            self.workspace.selectedTab?.title == "Upload source" && self.workspace.selectedTab?.state.isLoading == false
        }
        root.render()
        root.view.layoutIfNeeded()
        root.pageController.view.layoutIfNeeded()
        let runtime = try #require(workspace.selectedTab?.runtimeID)
        let view = try #require(engine.webView(for: runtime))
        try #require(view.window === window && !engine.hostView.isHidden)
        return view
    }

    func openPicker(input: String, view: WKWebView) async throws -> UIDocumentPickerViewController {
        _ = try await view.evaluateJavaScript("document.getElementById('\(input)').click()")
        try await uploadWait {
            self.controllers().contains { $0 is UIDocumentPickerViewController }
        }
        let picker = try #require(controllers().compactMap { $0 as? UIDocumentPickerViewController }.first)
        try await uploadWait { picker.viewIfLoaded?.window === self.window && !picker.isBeingPresented }
        return picker
    }

    func controllers() -> [UIViewController] {
        func descendants(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children
                .flatMap(descendants) + (controller.presentedViewController.map(descendants) ?? [])
        }
        return descendants(root)
    }

    func durableState() throws -> (BrowserTabSessionSnapshot?, [BrowserSyncQueuedMutation]) {
        try (store.loadSnapshotStrict(), store.pendingSyncQueue(for: owner))
    }

    func close() {
        root.dismiss(animated: false)
        workspace.onChange = nil
        engine.shutdown()
        server.stop()
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        preferences.removePersistentDomain(forName: preferencesName)
    }
}

@MainActor private func withUploadWebKit(_ body: (UploadWebKitFixture) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MobileUpload-\(UUID())")
    weak var store: BrowserSQLiteSessionStore?
    var failure: (any Error)?
    do {
        try await runUploadWebKit(directory: directory, observeStore: { store = $0 }, body)
    } catch {
        failure = error
    }
    // UIKit may retain an outgoing controller until the next run-loop turn.
    // Wait for actual SQLite ownership release before removing the directory.
    try await uploadWait { store == nil }
    try FileManager.default.removeItem(at: directory)
    if let failure {
        throw failure
    }
}

@MainActor private func runUploadWebKit(
    directory: URL,
    observeStore: (BrowserSQLiteSessionStore) -> Void,
    _ body: (UploadWebKitFixture) async throws -> Void,
) async throws {
    let fixture = try UploadWebKitFixture(directory: directory)
    observeStore(fixture.store)
    defer { fixture.close() }
    do {
        try await body(fixture)
    } catch {
        _ = await fixture.workspace.shutdown()
        throw error
    }
    #expect(await fixture.workspace.shutdown())
}

@MainActor private func uploadSelection(_ files: [URL], picker: UIDocumentPickerViewController) async throws {
    let delegate = try #require(picker.delegate)
    let select = try #require(delegate.documentPicker(_:didPickDocumentsAt:))
    // Public result injection on the installed delegate, not Files/provider UI.
    select(picker, files)
    await uploadDismiss(picker)
}

@MainActor private func uploadDismiss(_ picker: UIDocumentPickerViewController) async {
    guard picker.presentingViewController != nil else { return }
    await withCheckedContinuation { continuation in
        picker.dismiss(animated: false) { continuation.resume() }
    }
}

@MainActor private func uploadWait(_ condition: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(await condition())
}
