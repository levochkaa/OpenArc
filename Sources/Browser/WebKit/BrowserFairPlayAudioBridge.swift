// BrowserFairPlayAudioBridge.swift

import AVFoundation
import Foundation
import OSLog

private let fairPlayLog = Logger(subsystem: "com.levochkaa.OpenArc", category: "FairPlay")

// MARK: - BrowserFairPlayAudioBridge

/// Plays a Chromium page's FairPlay audio natively, for the renderer's FairPlay
/// bridge script. The page hands over its HLS playlist and the license server's
/// certificate; the player asks the page to exchange each license request for a
/// license, and reports where it is. One bridge serves one tab and plays one
/// track at a time.
@MainActor @objc final class BrowserFairPlayAudioBridge: NSObject {
    // MARK: Private

    /// A playlist arriving in parts.
    private struct Loading {
        let generation: Int
        var parts: [String?]
        var certificate: Data?
    }

    // MARK: Internal

    /// Whether the tab is muted, apart from the page's own volume and mute.
    @objc var tabMuted = false {
        didSet { applyVolume() }
    }

    private let send: @MainActor (String) -> Void
    private let player = AVPlayer()
    private var track: BrowserFairPlayTrack?
    private var loading: Loading?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var wantsToPlay = false
    private var volume: Float = 1
    private var muted = false
    private var seekSequence = 0

    /// `send` takes each event for the page's script as JSON.
    @objc init(send: @escaping @MainActor (String) -> Void) {
        self.send = send
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportPosition() }
        }
        self.statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reportPosition() }
        }
    }

    /// Takes one request from the page's script, as JSON.
    @objc func receive(_ json: String) {
        guard let data = json.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let operation = message["op"] as? String else { return }
        switch operation {
        case "load":
            receiveLoad(message)
        case "license":
            guard let generation = message["generation"] as? Int, generation == track?.generation,
                  let text = message["ckc"] as? String, let ckc = Data(base64Encoded: text) else { return }
            track?.license(ckc)
        case "play":
            wantsToPlay = true
            player.play()
            applyVolume()
        case "pause":
            wantsToPlay = false
            player.pause()
        case "seek":
            guard let time = message["time"] as? Double, time.isFinite, time >= 0 else { return }
            let sequence = message["sequence"] as? Int ?? 0
            seekSequence = max(seekSequence, sequence)
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportPosition() }
            }
        case "volume":
            volume = Float(min(max(message["volume"] as? Double ?? 1, 0), 1))
            applyVolume()
        case "muted":
            muted = message["muted"] as? Bool ?? false
            applyVolume()
        case "stop":
            stop()
        default:
            break
        }
    }

    /// Stops playing for good, as when the page leaves or the tab closes.
    @objc func stop() {
        wantsToPlay = false
        track?.cancel()
        track = nil
        loading = nil
        itemObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Fileprivate

    fileprivate func post(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        send(json)
    }

    private func receiveLoad(_ message: [String: Any]) {
        guard let generation = message["generation"] as? Int,
              let part = message["part"] as? Int, let count = message["parts"] as? Int,
              count > 0, count <= 1024, part >= 0, part < count,
              let text = message["playlist"] as? String else { return }
        if loading?.generation != generation {
            loading = Loading(generation: generation, parts: Array(repeating: nil, count: count))
        }
        guard var current = loading, current.parts.count == count else { return }
        current.parts[part] = text
        if let certificate = message["certificate"] as? String, !certificate.isEmpty {
            current.certificate = Data(base64Encoded: certificate)
        }
        volume = Float(min(max(message["volume"] as? Double ?? Double(volume), 0), 1))
        muted = message["muted"] as? Bool ?? muted
        loading = current
        guard current.parts.allSatisfy({ $0 != nil }) else { return }
        loading = nil
        let playlist = current.parts.compactMap(\.self).joined()
        guard let certificate = current.certificate, let data = playlist.data(using: .utf8) else {
            post(["event": "failed", "generation": generation])
            return
        }
        start(generation: generation, playlist: data, certificate: certificate)
    }

    private func start(generation: Int, playlist: Data, certificate: Data) {
        track?.cancel()
        wantsToPlay = false
        seekSequence = 0
        let track = BrowserFairPlayTrack(
            generation: generation,
            playlist: playlist,
            certificate: certificate,
            bridge: self,
        )
        self.track = track
        let item = AVPlayerItem(asset: track.asset)
        itemObservation = item.observe(\.status, options: [.new]) { [weak self, weak track] item, _ in
            MainActor.assumeIsolated {
                guard let self, let track, self.track === track else { return }
                switch item.status {
                case .readyToPlay:
                    guard !track.announcedReady else { return }
                    track.announcedReady = true
                    let duration = item.duration.seconds
                    self.post([
                        "event": "ready",
                        "generation": track.generation,
                        "duration": duration.isFinite ? duration : 0,
                    ])
                case .failed:
                    fairPlayLog
                        .error("Track \(track.generation) failed: \(String(describing: item.error), privacy: .public)")
                    track.fail()
                default:
                    break
                }
            }
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main,
        ) { [weak self, weak track] _ in
            MainActor.assumeIsolated {
                guard let self, let track, self.track === track else { return }
                self.wantsToPlay = false
                self.post(["event": "ended", "generation": track.generation])
            }
        }
        player.replaceCurrentItem(with: item)
        applyVolume()
    }

    private func applyVolume() {
        player.volume = volume
        player.isMuted = muted || tabMuted
    }

    private func reportPosition() {
        guard let track, track.announcedReady else { return }
        let time = player.currentTime().seconds
        post([
            "event": "position",
            "generation": track.generation,
            "time": time.isFinite ? max(time, 0) : 0,
            "playing": player.timeControlStatus == .playing,
            "sequence": seekSequence,
        ])
    }
}

// MARK: - BrowserFairPlayTrack

/// One playlist: it serves the playlist to AVFoundation under its own scheme and
/// passes each key request through the page.
@MainActor private final class BrowserFairPlayTrack: NSObject {
    // MARK: Internal

    let generation: Int
    let asset: AVURLAsset
    var announcedReady = false

    // MARK: Private

    private let certificate: Data
    private weak var bridge: BrowserFairPlayAudioBridge?
    private let loader: BrowserFairPlayPlaylistLoader
    private let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let keyDelegate = BrowserFairPlayKeyDelegate()
    private var waitingRequest: AVContentKeyRequest?
    private var licenseDeadline: Timer?
    private var cancelled = false
    private var failed = false

    init(generation: Int, playlist: Data, certificate: Data, bridge: BrowserFairPlayAudioBridge) {
        self.generation = generation
        self.certificate = certificate
        self.bridge = bridge
        self.loader = BrowserFairPlayPlaylistLoader(playlist: playlist)
        self.asset = AVURLAsset(url: URL(string: "\(BrowserFairPlayPlaylistLoader.scheme)://track/\(generation).m3u8")!)
        super.init()
        asset.resourceLoader.setDelegate(loader, queue: BrowserFairPlayPlaylistLoader.queue)
        keySession.setDelegate(keyDelegate, queue: .main)
        keyDelegate.track = self
        keySession.addContentKeyRecipient(asset)
    }

    func requestLicense(_ request: AVContentKeyRequest) {
        guard !cancelled else { return }
        let identifier = request.identifier as? String ?? ""
        let contentIdentifier = Data(identifier.replacingOccurrences(of: "skd://", with: "").utf8)
        let generation = generation
        request.makeStreamingContentKeyRequestData(
            forApp: certificate,
            contentIdentifier: contentIdentifier,
            options: nil,
        ) { [weak self] spc, error in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                guard let spc else {
                    fairPlayLog.error("No license request: \(String(describing: error), privacy: .public)")
                    self.fail()
                    return
                }
                self.waitingRequest = request
                self.licenseDeadline?.invalidate()
                self.licenseDeadline = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if self?.waitingRequest != nil {
                            fairPlayLog.error("The page sent no license in 30 seconds")
                            self?.fail()
                        }
                    }
                }
                self.bridge?.post([
                    "event": "request",
                    "generation": generation,
                    "spc": spc.base64EncodedString(),
                ])
            }
        }
    }

    func license(_ ckc: Data) {
        guard let request = waitingRequest, !cancelled else { return }
        waitingRequest = nil
        licenseDeadline?.invalidate()
        request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
    }

    func fail() {
        guard !cancelled, !failed else { return }
        failed = true
        bridge?.post(["event": "failed", "generation": generation])
        cancel()
    }

    func cancel() {
        cancelled = true
        licenseDeadline?.invalidate()
        waitingRequest = nil
        keySession.expire()
    }
}

// MARK: - BrowserFairPlayKeyDelegate

/// Hands the key session's requests to its track on the main queue.
private final class BrowserFairPlayKeyDelegate: NSObject, AVContentKeySessionDelegate {
    @MainActor weak var track: BrowserFairPlayTrack?

    func contentKeySession(_: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        MainActor.assumeIsolated { track?.requestLicense(keyRequest) }
    }

    func contentKeySession(
        _: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest,
    ) {
        MainActor.assumeIsolated { track?.requestLicense(keyRequest) }
    }

    func contentKeySession(
        _: AVContentKeySession,
        contentKeyRequest _: AVContentKeyRequest,
        didFailWithError error: any Error,
    ) {
        fairPlayLog.error("Key request failed: \(String(describing: error), privacy: .public)")
        MainActor.assumeIsolated { track?.fail() }
    }
}

// MARK: - BrowserFairPlayPlaylistLoader

/// Answers AVFoundation's request for the playlist; its segments and keys use their own addresses.
private final class BrowserFairPlayPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    // MARK: Internal

    static let scheme = "openarc-fairplay"
    static let queue = DispatchQueue(label: "com.levochkaa.OpenArc.fairplay.playlist")

    // MARK: Private

    private let playlist: Data

    init(playlist: Data) {
        self.playlist = playlist
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest,
    ) -> Bool {
        guard request.request.url?.scheme == Self.scheme else { return false }
        request.contentInformationRequest?.contentType = "public.m3u-playlist"
        request.contentInformationRequest?.contentLength = Int64(playlist.count)
        request.contentInformationRequest?.isByteRangeAccessSupported = false
        request.dataRequest?.respond(with: playlist)
        request.finishLoading()
        return true
    }
}
