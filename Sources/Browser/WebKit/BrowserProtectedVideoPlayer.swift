// BrowserProtectedVideoPlayer.swift

import AppKit
import AVFoundation
import CoreImage
import CoreMedia

// MARK: - BrowserProtectedVideoPlayer

/// One page media element's native player: its source buffers, the samples they
/// parsed, a display layer and an audio renderer on one synchronizer, and the
/// view that shows the layer over the element.
@MainActor final class BrowserProtectedVideoPlayer: NSObject {
    // MARK: Internal

    let media: Int
    let display = AVSampleBufferDisplayLayer()
    let audio = AVSampleBufferAudioRenderer()

    var tabMuted = false {
        didSet { applyVolume() }
    }

    // MARK: Private

    private weak var bridge: BrowserProtectedVideoBridge?
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let view = BrowserProtectedVideoView()
    private var videoLane: BrowserProtectedVideoLane!
    private var audioLane: BrowserProtectedVideoLane!
    private var buffers = [Int: BrowserProtectedVideoSourceBuffer]()
    private var ticker: Timer?
    private var decodeFailure: NSObjectProtocol?
    private var rect: BrowserProtectedVideoRect?
    private var naturalSize = (width: 0, height: 0)
    private var sentAudioMetadata = false
    private var sentInitData = Set<Data>()
    private var wantsToPlay = false
    private var stalled = true
    private var started = false
    private var rate: Float = 1
    private var volume: Float = 1
    private var muted = false
    private var duration = Double.infinity
    private var endOfStream = false
    private var endedSent = false
    private var seekSequence = 0
    private var reportedSeek = 0
    private var lastReport = ""

    // MARK: Fileprivate

    fileprivate var position: Double {
        let time = synchronizer.currentTime().seconds
        return time.isFinite ? max(time, 0) : 0
    }

    /// Lanes with samples: a source buffer may carry only audio or only video.
    private var activeLanes: [BrowserProtectedVideoLane] {
        [videoLane, audioLane].filter(\.hasSamples)
    }

    init(media: Int, bridge: BrowserProtectedVideoBridge) {
        self.media = media
        self.bridge = bridge
        super.init()
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.clear.cgColor
        synchronizer.addRenderer(display.sampleBufferRenderer)
        synchronizer.addRenderer(audio)
        self.videoLane = BrowserProtectedVideoLane(renderer: display.sampleBufferRenderer, isVideo: true)
        self.audioLane = BrowserProtectedVideoLane(renderer: audio, isVideo: false)
        view.displayLayer = display
        self.decodeFailure = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: display.sampleBufferRenderer,
            queue: .main,
        ) { notification in
            let error = notification.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
            protectedVideoLog.error("Video decode failed: \(String(describing: error), privacy: .public)")
        }
        self.ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func receive(_ operation: String, _ message: [String: Any], data: Data?) {
        switch operation {
        case "attach":
            volume = Float(message["volume"] as? Double ?? 1)
            muted = message["muted"] as? Bool ?? false
            applyVolume()
        case "addBuffer":
            guard let id = message["buffer"] as? Int else { return }
            buffers[id] = BrowserProtectedVideoSourceBuffer(id: id, player: self)
        case "removeBuffer":
            guard let id = message["buffer"] as? Int else { return }
            buffers[id] = nil
        case "append":
            guard let id = message["buffer"] as? Int, let buffer = buffers[id] else { return }
            let sequence = message["sequence"] as? Int ?? 0
            let windowEnd = message["windowEnd"] as? Double ?? -1
            let ok = buffer.append(
                data ?? Data(),
                offset: message["offset"] as? Double ?? 0,
                window: (message["windowStart"] as? Double ?? 0)...(windowEnd < 0 ? .infinity : windowEnd),
            )
            reply("appended", buffer: buffer, sequence: sequence, ok: ok)
            feed()
        case "remove":
            guard let id = message["buffer"] as? Int, let buffer = buffers[id] else { return }
            let start = message["start"] as? Double ?? 0
            let end = message["end"] as? Double ?? -1
            buffer.remove(from: start, to: end < 0 ? .infinity : end, position: position)
            reply("removed", buffer: buffer, sequence: message["sequence"] as? Int ?? 0, ok: true)
            feed()
        case "abort":
            guard let id = message["buffer"] as? Int else { return }
            buffers[id]?.abort()
        case "changeType":
            break
        case "duration":
            let duration = message["duration"] as? Double ?? -1
            self.duration = duration >= 0 ? duration : .infinity
        case "endOfStream":
            endOfStream = true
        case "reopen":
            endOfStream = false
            endedSent = false
        case "keys":
            break
        case "play":
            wantsToPlay = true
            if endedSent {
                endedSent = false
            }
            applyRate()
        case "pause":
            wantsToPlay = false
            applyRate()
        case "rate":
            let value = message["rate"] as? Double ?? 1
            rate = Float(max(0, min(value, 16)))
            applyRate()
        case "volume":
            volume = Float(min(max(message["volume"] as? Double ?? 1, 0), 1))
            muted = message["muted"] as? Bool ?? false
            applyVolume()
        case "seek":
            guard let time = message["time"] as? Double, time.isFinite, time >= 0 else { return }
            seekSequence = message["sequence"] as? Int ?? seekSequence
            seek(to: time)
        case "rect":
            rect = BrowserProtectedVideoRect(message)
            place()
        default:
            break
        }
    }

    // MARK: Samples

    /// A source buffer parsed samples of a kind: they join that kind's lane.
    func store(_ samples: [CMSampleBuffer], video: Bool, keyID: Data?) {
        let lane: BrowserProtectedVideoLane = video ? videoLane : audioLane
        if let keyID {
            lane.keyID = keyID
        }
        lane.store(samples, position: position)
        if video, let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) {
            let size = CMVideoFormatDescriptionGetPresentationDimensions(
                format,
                usePixelAspectRatio: true,
                useCleanAperture: true,
            )
            if Int(size.width) != naturalSize.width || Int(size.height) != naturalSize.height {
                naturalSize = (Int(size.width), Int(size.height))
                bridge?.post([
                    "event": "metadata",
                    "media": media,
                    "width": naturalSize.width,
                    "height": naturalSize.height,
                ])
            }
        } else if !video, naturalSize.width == 0, !sentAudioMetadata {
            sentAudioMetadata = true
            bridge?.post(["event": "metadata", "media": media, "width": 0, "height": 0])
        }
    }

    /// Init data a fragment carried: the page learns it as an `encrypted` event, once.
    func encrypted(_ data: Data) {
        guard !sentInitData.contains(data) else { return }
        sentInitData.insert(data)
        bridge?.post(["event": "encrypted", "media": media, "type": "sinf", "data": data.base64EncodedString()])
    }

    func keysChanged() {
        feed()
    }

    func lane(video: Bool) -> BrowserProtectedVideoLane? {
        video ? videoLane : audioLane
    }

    func close() {
        ticker?.invalidate()
        ticker = nil
        if let decodeFailure {
            NotificationCenter.default.removeObserver(decodeFailure)
        }
        decodeFailure = nil
        synchronizer.rate = 0
        videoLane.stop()
        audioLane.stop()
        display.sampleBufferRenderer.flush(removingDisplayedImage: true) {}
        audio.flush()
        buffers.removeAll()
        view.removeFromSuperview()
    }

    /// Puts the view over the element's place on the page, or hides it.
    func place() {
        guard let pageView = bridge?.pageView, let host = pageView.superview, let rect, rect.visible,
              !pageView.isHidden, rect.width > 1, rect.height > 1
        else {
            view.isHidden = true
            return
        }
        // CSS pixels to the page view's points: zoom scales both.
        let scale = rect.devicePixelRatio / max(pageView.window?.backingScaleFactor ?? 2, 1)
        let height = pageView.bounds.height
        let y = pageView.isFlipped ? rect.y * scale : height - (rect.y + rect.height) * scale
        let inPage = NSRect(x: rect.x * scale, y: y, width: rect.width * scale, height: rect.height * scale)
        let visible = inPage.intersection(pageView.bounds)
        guard !visible.isEmpty else {
            view.isHidden = true
            return
        }
        if view.superview !== host {
            host.addSubview(view, positioned: .above, relativeTo: pageView)
        } else if let index = host.subviews.firstIndex(of: view), let page = host.subviews.firstIndex(of: pageView),
                  index != page + 1
        {
            host.addSubview(view, positioned: .above, relativeTo: pageView)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = pageView.convert(visible, to: host)
        // The layer keeps the element's full size; the view clips what lies off the page.
        let full = pageView.convert(inPage, to: host)
        display.frame = NSRect(
            x: full.minX - view.frame.minX,
            y: full.minY - view.frame.minY,
            width: full.width,
            height: full.height,
        )
        display.videoGravity = rect.gravity
        CATransaction.commit()
        view.isHidden = false
    }

    private func reply(_ event: String, buffer: BrowserProtectedVideoSourceBuffer, sequence: Int, ok: Bool) {
        bridge?.post([
            "event": event,
            "media": media,
            "buffer": buffer.id,
            "sequence": sequence,
            "ok": ok,
            "ranges": buffer.ranges.map { [$0.lowerBound, $0.upperBound] },
        ])
    }

    private func applyVolume() {
        audio.volume = volume
        audio.isMuted = muted || tabMuted
    }

    /// Seconds of continuous samples ahead of `time` in every active lane.
    private func bufferedAhead(of time: Double) -> Double {
        let lanes = activeLanes
        guard !lanes.isEmpty else { return 0 }
        return lanes.map { $0.bufferedAhead(of: time) }.min() ?? 0
    }

    private func feed() {
        if !started {
            // The first samples start the clock at the earliest buffered time.
            guard let start = activeLanes.compactMap(\.firstTime).min() else { return }
            started = true
            synchronizer.setRate(0, time: CMTime(seconds: start, preferredTimescale: 90000))
            videoLane.cue(at: start)
            audioLane.cue(at: start)
        }
        for lane in [videoLane!, audioLane!] {
            lane.contentKey = lane.keyID.flatMap { bridge?.contentKey(for: $0) }
            lane.isBlocked = lane.keyID != nil && lane.contentKey == nil
            lane.feed()
        }
        tick()
    }

    private func seek(to time: Double) {
        endedSent = false
        synchronizer.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90000))
        started = true
        videoLane.cue(at: time)
        audioLane.cue(at: time)
        stalled = true
        feed()
        reportedSeek = 0
        tick(force: true)
    }

    private func applyRate() {
        let running = wantsToPlay && !stalled && started
        let target = running ? rate : 0
        if synchronizer.rate != target {
            synchronizer.rate = target
        }
        tick(force: true)
    }

    private func tick(force: Bool = false) {
        let now = position
        let ahead = bufferedAhead(of: now)
        let ending = endOfStream && ahead < 0.05 && activeLanes.contains { $0.lastEnd.map { now >= $0 - 0.1 } ?? false }
        if ending, wantsToPlay, !endedSent {
            endedSent = true
            wantsToPlay = false
            synchronizer.rate = 0
            bridge?.post(["event": "ended", "media": media, "time": min(now, duration)])
            return
        }
        if !stalled, wantsToPlay, ahead < 0.05, !endOfStream {
            stalled = true
            synchronizer.rate = 0
        } else if stalled, ahead >= 1 || (endOfStream && ahead > 0) {
            stalled = false
            if wantsToPlay {
                synchronizer.rate = rate
            }
        }
        let running = synchronizer.rate > 0
        let seeked = seekSequence != reportedSeek && (ahead > 0 || endOfStream)
        if seeked {
            reportedSeek = seekSequence
        }
        let message: [String: Any] = [
            "event": "time",
            "media": media,
            "time": now,
            "running": running,
            "sequence": seekSequence,
            "seeked": seeked,
            "frames": videoLane.enqueuedCount,
        ]
        let key = "\(running)|\(seeked)|\(seekSequence)|\(Int(now * 4))"
        guard force || seeked || key != lastReport || running else { return }
        lastReport = key
        bridge?.post(message)
    }
}

// MARK: - BrowserProtectedVideoRect

/// The element's box on the page, in CSS pixels, as the page reported it.
struct BrowserProtectedVideoRect {
    // MARK: Internal

    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let visible: Bool
    let devicePixelRatio: Double
    let gravity: AVLayerVideoGravity

    init?(_ message: [String: Any]) {
        guard let x = message["x"] as? Double, let y = message["y"] as? Double,
              let width = message["width"] as? Double, let height = message["height"] as? Double else { return nil }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.visible = message["visible"] as? Bool ?? false
        self.devicePixelRatio = message["dpr"] as? Double ?? 2
        self.gravity =
            switch message["fit"] as? String {
            case "cover": .resizeAspectFill
            case "fill": .resize
            default: .resizeAspect
            }
    }
}

// MARK: - BrowserProtectedVideoView

/// Shows the display layer over the page. The layer is blended with the page
/// under it (screen), so the site's controls and subtitles, drawn bright over
/// the black player, show over the video. Clicks and scrolls go to the page.
final class BrowserProtectedVideoView: NSView {
    override var isOpaque: Bool { false }

    // MARK: Internal

    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            guard let displayLayer else { return }
            layer?.addSublayer(displayLayer)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        // The view's own layer, a sibling of the page's, blends with the page.
        layer?.compositingFilter = CIFilter(name: "CIScreenBlendMode")
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - BrowserProtectedVideoLane

/// One kind of samples, video or audio: kept in decode order, fed to its
/// renderer from a cue point on.
@MainActor final class BrowserProtectedVideoLane {
    // MARK: Internal

    struct Sample {
        let buffer: CMSampleBuffer
        let start: Double
        let end: Double
        let decode: Double
        let isSync: Bool
    }

    let isVideo: Bool
    var keyID: Data?
    /// Decrypts the lane's samples; attached to each before it is fed.
    var contentKey: AVContentKey?
    var isBlocked = false
    private(set) var enqueuedCount = 0

    // MARK: Private

    private let renderer: any AVQueuedSampleBufferRendering
    private var samples = [Sample]()
    private var cachedRanges: [ClosedRange<Double>]?
    private var cursor: Int?
    private var cueTime = 0.0
    private var hiddenUntil = 0.0
    private var requesting = false
    /// The decode time of the last sample fed, to find the next after storage changes.
    private var lastFed: Double?

    var hasSamples: Bool { !samples.isEmpty }
    var firstTime: Double? { samples.map(\.start).min() }
    var lastEnd: Double? { samples.map(\.end).max() }

    /// Continuous ranges of presentation time, gaps under a third of a second joined.
    var ranges: [ClosedRange<Double>] {
        if let cachedRanges {
            return cachedRanges
        }
        var result = [ClosedRange<Double>]()
        for sample in samples.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, sample.start <= last.upperBound + 0.3 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, sample.end)
            } else {
                result.append(sample.start...max(sample.start, sample.end))
            }
        }
        cachedRanges = result
        return result
    }

    init(renderer: any AVQueuedSampleBufferRendering, isVideo: Bool) {
        self.renderer = renderer
        self.isVideo = isVideo
    }

    private static func sample(_ buffer: CMSampleBuffer) -> Sample? {
        let start = CMSampleBufferGetOutputPresentationTimeStamp(buffer).seconds
        let decodeTime = CMSampleBufferGetDecodeTimeStamp(buffer)
        let decode = decodeTime.isValid ? decodeTime.seconds : start
        let duration = CMSampleBufferGetOutputDuration(buffer).seconds
        guard start.isFinite else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            buffer,
            createIfNecessary: false,
        ) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return Sample(
            buffer: buffer,
            start: start,
            end: start + (duration.isFinite && duration > 0 ? duration : 0.02),
            decode: decode.isFinite ? decode : start,
            isSync: !notSync,
        )
    }

    /// A copy that decodes without being shown, for frames before a seek target.
    private static func hidden(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: nil, sampleBuffer: buffer, sampleBufferOut: &copy) == noErr,
              let copy,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return buffer }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque(),
        )
        return copy
    }

    func bufferedAhead(of time: Double) -> Double {
        for range in ranges where time >= range.lowerBound - 0.1 && time < range.upperBound {
            return range.upperBound - time
        }
        return 0
    }

    /// New samples replace the stored ones they overlap, as a source buffer does.
    func store(_ new: [CMSampleBuffer], position _: Double) {
        let parsed = new.compactMap(Self.sample)
        guard let low = parsed.map(\.start).min(), let high = parsed.map(\.end).max() else { return }
        samples.removeAll { $0.start >= low - 0.001 && $0.start < high - 0.001 }
        samples.append(contentsOf: parsed)
        samples.sort { $0.decode < $1.decode }
        cachedRanges = nil
        recue()
    }

    func remove(from start: Double, to end: Double) {
        samples.removeAll { $0.start >= start && $0.start < end }
        cachedRanges = nil
        recue()
    }

    /// The next feed starts at `time`: video from the sync sample before it,
    /// with the samples before `time` decoded but not shown.
    func cue(at time: Double) {
        renderer.flush()
        renderer.stopRequestingMediaData()
        requesting = false
        cueTime = time
        cursor = nil
        hiddenUntil = time
        lastFed = nil
        locateCursor()
    }

    func stop() {
        renderer.stopRequestingMediaData()
        requesting = false
        samples.removeAll()
        cachedRanges = nil
    }

    func feed() {
        if cursor == nil {
            locateCursor()
        }
        guard !isBlocked, !requesting, let cursor, cursor < samples.count else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    /// Storage changed: the cursor follows the last fed sample's decode time.
    private func recue() {
        guard let lastFed else {
            if cursor != nil {
                cursor = nil
            }
            return
        }
        cursor = samples.firstIndex { $0.decode > lastFed + 0.0001 } ?? samples.count
    }

    private func locateCursor() {
        guard !samples.isEmpty else { return }
        if isVideo {
            // The last sync sample at or before the cue point, in decode order.
            var index: Int?
            for (position, sample) in samples.enumerated() where sample.isSync && sample.start <= cueTime + 0.001 {
                index = position
            }
            if index == nil, let first = samples.firstIndex(where: { $0.isSync && $0.start >= cueTime - 0.5 }) {
                index = first
            }
            cursor = index
        } else {
            cursor = samples
                .firstIndex { $0.end > cueTime } ?? (samples.last.map { $0.end > cueTime } == true ? 0 : nil)
        }
    }

    private func pump() {
        while renderer.isReadyForMoreMediaData, !isBlocked, let index = cursor, index < samples.count {
            let sample = samples[index]
            let buffer = isVideo && sample.end <= hiddenUntil ? Self.hidden(sample.buffer) : sample.buffer
            if let contentKey {
                var error: NSError?
                if !AVSampleBufferAttachContentKey(buffer, contentKey, &error) {
                    protectedVideoLog.error("Attaching a key failed: \(String(describing: error), privacy: .public)")
                }
            }
            renderer.enqueue(buffer)
            enqueuedCount += 1
            lastFed = sample.decode
            cursor = index + 1
        }
        if isBlocked || (cursor ?? 0) >= samples.count {
            renderer.stopRequestingMediaData()
            requesting = false
        }
    }
}

// MARK: - BrowserProtectedVideoSourceBuffer

/// One page SourceBuffer: AVFoundation's stream parser turns its fragments into
/// samples, which go to the player's lanes, shifted by the timestamp offset and
/// cut to the append window.
@MainActor final class BrowserProtectedVideoSourceBuffer: NSObject {
    // MARK: Internal

    let id: Int

    // MARK: Private

    private weak var player: BrowserProtectedVideoPlayer?
    private var parser: BrowserStreamDataParser?
    private var offset = 0.0
    private var window = 0.0...Double.infinity
    private var parseFailed = false
    private var pendingVideo = [CMSampleBuffer]()
    private var pendingAudio = [CMSampleBuffer]()
    private var trackKinds = [Int32: Bool]()
    private var initData = [Int32: Data]()
    private var kinds = Set<Bool>()

    /// Presentation ranges of the kinds this buffer carries.
    var ranges: [ClosedRange<Double>] {
        let lanes = kinds.map { $0 ? player?.lane(video: true) : player?.lane(video: false) }.compactMap(\.self)
        guard var result = lanes.first?.ranges else { return [] }
        for lane in lanes.dropFirst() {
            result = Self.intersect(result, lane.ranges)
        }
        return result
    }

    init(id: Int, player: BrowserProtectedVideoPlayer) {
        self.id = id
        self.player = player
        super.init()
        self.parser = BrowserStreamDataParser(delegate: self)
    }

    private static func intersect(
        _ first: [ClosedRange<Double>],
        _ second: [ClosedRange<Double>],
    ) -> [ClosedRange<Double>] {
        var result = [ClosedRange<Double>]()
        for a in first {
            for b in second {
                let low = max(a.lowerBound, b.lowerBound)
                let high = min(a.upperBound, b.upperBound)
                if high > low {
                    result.append(low...high)
                }
            }
        }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Each sample of a buffer that holds several.
    private static func singles(_ buffer: CMSampleBuffer) -> [CMSampleBuffer] {
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 1 else { return [buffer] }
        return (0..<count).compactMap { index in
            var single: CMSampleBuffer?
            let status = CMSampleBufferCopySampleBufferForRange(
                allocator: nil,
                sampleBuffer: buffer,
                sampleRange: CFRange(location: index, length: 1),
                sampleBufferOut: &single,
            )
            return status == noErr ? single : nil
        }
    }

    private static func shift(_ buffer: CMSampleBuffer, by offset: Double) -> CMSampleBuffer? {
        guard offset != 0 else { return buffer }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(buffer, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        let delta = CMTime(seconds: offset, preferredTimescale: timing.presentationTimeStamp.timescale)
        timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, delta)
        if timing.decodeTimeStamp.isValid {
            timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, delta)
        }
        var shifted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &shifted,
        )
        return status == noErr ? shifted : nil
    }

    func append(_ data: Data, offset: Double, window: ClosedRange<Double>) -> Bool {
        guard let parser, !data.isEmpty else { return parser != nil }
        self.offset = offset
        self.window = window
        parseFailed = false
        parser.append(data)
        flushParsed()
        return !parseFailed
    }

    func remove(from start: Double, to end: Double, position _: Double) {
        for kind in kinds {
            player?.lane(video: kind)?.remove(from: start, to: end)
        }
    }

    func abort() {
        parser = BrowserStreamDataParser(delegate: self)
        pendingVideo.removeAll()
        pendingAudio.removeAll()
    }

    // MARK: Parser callbacks

    func parserFailed(_ error: (any Error)?) {
        protectedVideoLog.error("Fragment parse failed: \(String(describing: error), privacy: .public)")
        parseFailed = true
    }

    func parser(provided sample: CMSampleBuffer, trackID: Int32, mediaType: String) {
        let video = mediaType == AVMediaType.video.rawValue
        guard video || mediaType == AVMediaType.audio.rawValue else { return }
        for single in Self.singles(sample) {
            guard let shifted = Self.shift(single, by: offset) else { continue }
            let start = CMSampleBufferGetOutputPresentationTimeStamp(shifted).seconds
            guard window.contains(start) else { continue }
            if video {
                pendingVideo.append(shifted)
            } else {
                pendingAudio.append(shifted)
            }
        }
        trackKinds[trackID] = video
        kinds.insert(video)
    }

    func parser(providedInitData data: Data, trackID: Int32) {
        initData[trackID] = data
        player?.encrypted(data)
    }

    private func flushParsed() {
        let keyFor = { (video: Bool) -> Data? in
            for (track, kind) in self.trackKinds where kind == video {
                if let data = self.initData[track] {
                    return BrowserFairPlayInitData.sinfKeyIDs(data).first
                }
            }
            return nil
        }
        if !pendingVideo.isEmpty {
            player?.store(pendingVideo, video: true, keyID: keyFor(true))
            pendingVideo.removeAll()
        }
        if !pendingAudio.isEmpty {
            player?.store(pendingAudio, video: false, keyID: keyFor(false))
            pendingAudio.removeAll()
        }
    }
}

// MARK: - BrowserStreamDataParser

/// AVFoundation's stream parser, which WebKit uses for Media Source: it turns
/// fragmented MP4 into sample buffers and reports the init data of encrypted
/// tracks. It has no public interface, so its methods are called by name.
@MainActor final class BrowserStreamDataParser: NSObject {
    // MARK: Private

    private let parser: NSObject
    private weak var owner: BrowserProtectedVideoSourceBuffer?

    init?(delegate: BrowserProtectedVideoSourceBuffer) {
        guard let type = NSClassFromString("AVStreamDataParser") as? NSObject.Type else { return nil }
        self.parser = type.init()
        self.owner = delegate
        super.init()
        parser.perform(NSSelectorFromString("setDelegate:"), with: self)
    }

    isolated deinit {
        parser.perform(NSSelectorFromString("setDelegate:"), with: nil)
    }

    // MARK: Internal

    func append(_ data: Data) {
        parser.perform(NSSelectorFromString("appendStreamData:"), with: data as NSData)
        parser.perform(NSSelectorFromString("providePendingMediaData"))
    }

    // MARK: Parser delegate

    @objc(streamDataParser:didParseStreamDataAsAsset:)
    func streamDataParser(_: AnyObject, didParseStreamDataAsAsset _: AVAsset) {}

    @objc(streamDataParser:didParseStreamDataAsAsset:withDiscontinuity:)
    func streamDataParser(_: AnyObject, didParseStreamDataAsAsset _: AVAsset, withDiscontinuity _: Bool) {}

    @objc(streamDataParser:didFailToParseStreamDataWithError:)
    func streamDataParser(_: AnyObject, didFailToParseStreamDataWithError error: NSError?) {
        owner?.parserFailed(error)
    }

    @objc(streamDataParser:didProvideMediaData:forTrackID:mediaType:flags:) func streamDataParser(
        _: AnyObject,
        didProvideMediaData sample: CMSampleBuffer,
        forTrackID trackID: Int32,
        mediaType: String,
        flags _: UInt,
    ) {
        owner?.parser(provided: sample, trackID: trackID, mediaType: mediaType)
    }

    @objc(streamDataParserWillProvideContentKeyRequestInitializationData:forTrackID:)
    func streamDataParserWillProvideContentKeyRequestInitializationData(_: AnyObject, forTrackID _: Int32) {}

    @objc(streamDataParser:didProvideContentKeyRequestInitializationData:forTrackID:) func streamDataParser(
        _: AnyObject,
        didProvideContentKeyRequestInitializationData data: Data,
        forTrackID trackID: Int32,
    ) {
        owner?.parser(providedInitData: data, trackID: trackID)
    }
}
