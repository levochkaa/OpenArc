// BrowserProtectedVideoBridge.swift

import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import OSLog

let protectedVideoLog = Logger(subsystem: "com.levochkaa.OpenArc", category: "ProtectedVideo")

// MARK: - BrowserProtectedVideoBridge

/// Plays a Chromium tab's protected video natively, for the renderer's video
/// bridge script, which gives the site Media Source and EME objects of its own.
/// Each of the page's media elements gets a player: its fragments are parsed
/// with AVFoundation's stream parser, kept, and fed to a display layer and an
/// audio renderer that share a clock. The layer is drawn over the element's
/// place on the page, blended so that the site's controls and subtitles, drawn
/// on the black player behind it, stay visible. FairPlay keys go through one
/// content key session; the page exchanges its license requests.
@MainActor @objc final class BrowserProtectedVideoBridge: NSObject {
    // MARK: Internal

    /// The tab's page view; videos are drawn over it, in its superview.
    @objc weak var pageView: NSView? {
        didSet { layout() }
    }

    /// Whether the tab is muted, apart from the page's own volume.
    @objc var tabMuted = false {
        didSet { players.values.forEach { $0.tabMuted = tabMuted } }
    }

    // MARK: Private

    private let send: @MainActor (String) -> Void
    private var players = [Int: BrowserProtectedVideoPlayer]()
    private let keys = BrowserProtectedVideoKeys()

    /// `send` takes each event for the page's script as JSON.
    @objc init(send: @escaping @MainActor (String) -> Void) {
        self.send = send
        super.init()
        keys.bridge = self
    }

    /// Takes one request from the page's script: JSON and, for a fragment, its bytes.
    @objc func receive(_ json: String, data: Data?) {
        guard let raw = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let operation = message["op"] as? String else { return }
        switch operation {
        case "reset":
            reset()
        case "certificate", "keyClose", "keyRequest", "keyUpdate":
            keys.receive(operation, message)
        default:
            guard let media = message["media"] as? Int else { return }
            if operation == "attach" {
                players[media]?.close()
                let player = BrowserProtectedVideoPlayer(media: media, bridge: self)
                player.tabMuted = tabMuted
                players[media] = player
            }
            guard let player = players[media] else { return }
            if operation == "detach" {
                player.close()
                players[media] = nil
                return
            }
            player.receive(operation, message, data: data)
        }
    }

    /// Places every video over the page again, as after the page view moved or hid.
    @objc func layout() {
        players.values.forEach { $0.place() }
    }

    /// Stops every player, as when the page leaves or the tab closes.
    @objc func reset() {
        players.values.forEach { $0.close() }
        players.removeAll()
        keys.reset()
    }

    func post(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        send(json)
    }

    func keysBecameUsable() {
        players.values.forEach { $0.keysChanged() }
    }

    /// The key that decrypts samples with this key ID, once the page's license arrived.
    func contentKey(for keyID: Data) -> AVContentKey? {
        keys.contentKeys[keyID]
    }
}

// MARK: - BrowserProtectedVideoKeys

/// One FairPlay content key session for the tab's players. The page's key
/// sessions ask for keys with init data; each key request's SPC goes to the
/// session that asked, and its license comes back to the request.
@MainActor final class BrowserProtectedVideoKeys: NSObject {
    // MARK: Private

    /// A page's key session: which MediaKeys made it and how it exchanges licenses.
    private final class PageSession {
        // MARK: Internal

        let keys: Int
        let raw: Bool
        var awaitingKeyID: Data?
        var rawQueue = [(keyID: Data, spc: Data)]()

        init(keys: Int, keySystem: String) {
            self.keys = keys
            // FairPlay 3 sends JSON lists of key IDs and payloads; earlier
            // versions send one bare request and take one bare license.
            self.raw = keySystem != "com.apple.fps.3_0"
        }
    }

    // MARK: Internal

    weak var bridge: BrowserProtectedVideoBridge?
    /// Keys from licenses, by key ID; players attach them to encrypted samples.
    private(set) var contentKeys = [Data: AVContentKey]()

    private lazy var session: AVContentKeySession = {
        let session = AVContentKeySession(keySystem: .fairPlayStreaming)
        session.setDelegate(delegate, queue: delegateQueue)
        return session
    }()

    private let delegate = BrowserProtectedVideoKeyDelegate()
    private let delegateQueue = DispatchQueue(label: "com.levochkaa.OpenArc.protected-video.keys")
    private var certificates = [Int: Data]()
    private var pageSessions = [Int: PageSession]()
    private var requests = [Data: AVContentKeyRequest]()
    private var owners = [Data: Int]()
    private var lastSession: Int?
    private var waiting = [Data]()

    override init() {
        super.init()
        delegate.keys = self
    }

    static func keyID(of request: AVContentKeyRequest) -> Data? {
        if let data = request.identifier as? Data, data.count == 16 {
            return data
        }
        if let text = request.identifier as? String, text.hasPrefix("skd://") {
            return Data(hexString: String(text.dropFirst(6)))
        }
        guard let initialization = request.initializationData else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: initialization) as? [String: Any],
           let pssh = (object["pssh"] as? String).flatMap({ Data(base64Encoded: $0) })
        {
            return BrowserFairPlayInitData.psshKeyIDs(pssh).first
        }
        return BrowserFairPlayInitData.sinfKeyIDs(initialization).first
    }

    private static func data(_ value: Any?) -> Data? {
        (value as? String).flatMap { Data(base64Encoded: $0) }
    }

    func reset() {
        certificates.removeAll()
        pageSessions.removeAll()
        requests.removeAll()
        owners.removeAll()
        contentKeys.removeAll()
    }

    func receive(_ operation: String, _ message: [String: Any]) {
        switch operation {
        case "certificate":
            guard let keys = message["keys"] as? Int, let data = Self.data(message["data"]) else { return }
            certificates[keys] = data
            protectedVideoLog.info("Certificate for keys \(keys): \(data.count) bytes")
            flush()
        case "keyRequest":
            keyRequest(message)
        case "keyUpdate":
            guard let id = message["session"] as? Int, let data = Self.data(message["data"]) else { return }
            keyUpdate(session: id, data: data)
        case "keyClose":
            guard let id = message["session"] as? Int else { return }
            pageSessions[id] = nil
        default:
            break
        }
    }

    func didProvide(_ request: AVContentKeyRequest) {
        guard let keyID = Self.keyID(of: request) else {
            protectedVideoLog
                .error("A key request without a key ID: \(String(describing: request.identifier), privacy: .public)")
            return
        }
        requests[keyID] = request
        waiting.append(keyID)
        flush()
    }

    func didSucceed(_ request: AVContentKeyRequest) {
        guard let keyID = Self.keyID(of: request), let contentKey = request.contentKey else { return }
        contentKeys[keyID] = contentKey
        protectedVideoLog.info("Key \(keyID.hexString, privacy: .public) usable")
        if let owner = owners[keyID] {
            bridge?.post(["event": "keys", "session": owner, "ok": true, "keyIDs": [keyID.base64EncodedString()]])
        }
        bridge?.keysBecameUsable()
    }

    func didFail(_ request: AVContentKeyRequest, error: any Error) {
        guard let keyID = Self.keyID(of: request) else { return }
        protectedVideoLog
            .error("Key \(keyID.hexString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        requests[keyID] = nil
        if let owner = owners[keyID], let pageSession = pageSessions[owner] {
            if pageSession.awaitingKeyID == keyID {
                pageSession.awaitingKeyID = nil
                askPageForNextRawKey(session: owner)
            }
            bridge?.post(["event": "keys", "session": owner, "ok": false, "keyIDs": [keyID.base64EncodedString()]])
        }
    }

    private func keyRequest(_ message: [String: Any]) {
        guard let id = message["session"] as? Int, let keys = message["keys"] as? Int,
              let keySystem = message["keySystem"] as? String, keySystem.hasPrefix("com.apple.fps"),
              let type = message["type"] as? String, let data = Self.data(message["data"]),
              !data.isEmpty, data.count < 64 * 1024 else { return }
        var keyIDs = [Data]()
        var initialization: Data?
        switch type {
        case "sinf":
            keyIDs = BrowserFairPlayInitData.sinfKeyIDs(data)
            initialization = data
        case "cenc":
            if let pssh = BrowserFairPlayInitData.fairPlayPssh(data) {
                keyIDs = BrowserFairPlayInitData.psshKeyIDs(pssh)
                initialization = try? JSONSerialization.data(withJSONObject: ["pssh": pssh.base64EncodedString()])
            }
        default:
            break
        }
        guard !keyIDs.isEmpty, let initialization else {
            protectedVideoLog.error(
                "No key IDs in \(type, privacy: .public) init data: \(data.base64EncodedString(), privacy: .public)",
            )
            bridge?.post(["event": "keys", "session": id, "ok": false])
            return
        }
        if pageSessions[id] == nil {
            pageSessions[id] = PageSession(keys: keys, keySystem: keySystem)
        }
        lastSession = id
        for keyID in keyIDs {
            owners[keyID] = id
        }
        protectedVideoLog.info(
            "\(type, privacy: .public) request for \(keyIDs.count) keys from session \(id), \(keySystem, privacy: .public)",
        )
        session.processContentKeyRequest(
            withIdentifier: nil,
            initializationData: initialization,
            options: ["InitializationDataType": type],
        )
    }

    /// Asks for an SPC for each waiting key request whose session's certificate is known.
    private func flush() {
        let pending = waiting
        waiting.removeAll()
        for keyID in pending {
            guard let request = requests[keyID] else { continue }
            guard let owner = owners[keyID] ?? lastSession, let pageSession = pageSessions[owner],
                  let certificate = certificates[pageSession.keys] ?? certificates.values.first
            else {
                protectedVideoLog.info("Key \(keyID.hexString, privacy: .public) waits for a certificate")
                waiting.append(keyID)
                continue
            }
            owners[keyID] = owner
            request.makeStreamingContentKeyRequestData(
                forApp: certificate,
                contentIdentifier: keyID,
                options: nil,
            ) { [weak self] spc, error in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard let spc else {
                            protectedVideoLog
                                .error(
                                    "No SPC for \(keyID.hexString, privacy: .public): \(String(describing: error), privacy: .public)",
                                )
                            return
                        }
                        self.deliver(spc: spc, keyID: keyID, session: owner)
                    }
                }
            }
        }
    }

    private func deliver(spc: Data, keyID: Data, session id: Int) {
        guard let pageSession = pageSessions[id] else { return }
        protectedVideoLog.info("SPC for \(keyID.hexString, privacy: .public): \(spc.count) bytes to session \(id)")
        if pageSession.raw {
            pageSession.rawQueue.append((keyID, spc))
            askPageForNextRawKey(session: id)
            return
        }
        let entries = [["keyID": keyID.base64EncodedString(), "payload": spc.base64EncodedString()]]
        guard let message = try? JSONSerialization.data(withJSONObject: entries) else { return }
        bridge?.post(["event": "message", "session": id, "data": message.base64EncodedString()])
    }

    private func askPageForNextRawKey(session id: Int) {
        guard let pageSession = pageSessions[id] else { return }
        while pageSession.awaitingKeyID == nil, !pageSession.rawQueue.isEmpty {
            let next = pageSession.rawQueue.removeFirst()
            guard requests[next.keyID] != nil else { continue }
            pageSession.awaitingKeyID = next.keyID
            bridge?.post(["event": "message", "session": id, "data": next.spc.base64EncodedString()])
        }
    }

    private func keyUpdate(session id: Int, data: Data) {
        guard let pageSession = pageSessions[id] else { return }
        protectedVideoLog.info("License for session \(id): \(data.count) bytes")
        if pageSession.raw {
            if let keyID = pageSession.awaitingKeyID, let request = requests.removeValue(forKey: keyID) {
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: data))
            }
            pageSession.awaitingKeyID = nil
            askPageForNextRawKey(session: id)
            return
        }
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for entry in entries {
            guard let keyID = Self.data(entry["keyID"]), let request = requests.removeValue(forKey: keyID) else {
                continue
            }
            if let payload = Self.data(entry["payload"]), !payload.isEmpty {
                request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: payload))
            } else {
                request.processContentKeyResponseError(NSError(domain: "OpenArc.ProtectedVideo", code: 1))
            }
        }
    }
}

// MARK: - BrowserProtectedVideoKeyDelegate

/// Hands the content key session's callbacks to the main actor.
private final class BrowserProtectedVideoKeyDelegate: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    @MainActor weak var keys: BrowserProtectedVideoKeys?

    func contentKeySession(_: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.keys?.didProvide(keyRequest) } }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest,
    ) {
        contentKeySession(session, didProvide: keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequests: [AVContentKeyRequest],
        forInitializationData _: Data?,
    ) {
        for request in keyRequests {
            contentKeySession(session, didProvide: request)
        }
    }

    func contentKeySession(_: AVContentKeySession, contentKeyRequestDidSucceed keyRequest: AVContentKeyRequest) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.keys?.didSucceed(keyRequest) } }
    }

    func contentKeySession(
        _: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: any Error,
    ) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.keys?.didFail(keyRequest, error: error) } }
    }
}

// MARK: - Data

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let characters = Array(hexString.lowercased())
        guard characters.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
