// BrowserDownloadFlightView.swift

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: - BrowserDownloadProjectile

/// The badge's path: straight across and thrown against gravity, shrinking as it falls.
struct BrowserDownloadProjectile {
    // MARK: Private

    private static let gravity: CGFloat = 2534

    // MARK: Internal

    let source: CGPoint
    let destination: CGPoint

    /// 1.05 s over 930 pt and 1.2 s over 1590 pt.
    var duration: TimeInterval {
        0.84 + 0.000228 * hypot(destination.x - source.x, destination.y - source.y)
    }

    func center(at time: TimeInterval) -> CGPoint {
        let velocityY = (destination.y - source.y) / duration - Self.gravity * duration / 2
        return CGPoint(
            x: source.x + (destination.x - source.x) * time / duration,
            y: source.y + velocityY * time + Self.gravity * time * time / 2,
        )
    }

    func diameter(at time: TimeInterval) -> CGFloat {
        let progress = min(max(time / duration, 0), 1)
        let keys: [(CGFloat, CGFloat)] = [(0, 26), (0.18, 38), (0.46, 27), (0.6, 21), (0.8, 14), (1, 8)]
        for (start, end) in zip(keys, keys.dropFirst()) where progress <= end.0 {
            return start.1 + (end.1 - start.1) * (progress - start.0) / (end.0 - start.0)
        }
        return keys[keys.count - 1].1
    }
}

// MARK: - BrowserDownloadBinMotion

/// With the sidebar hidden, a small bin slides in from the window's edge, and the badge bounces off its corner.
enum BrowserDownloadBinMotion {
    static let binSize: CGFloat = 46
    static let binRestX: CGFloat = 31
    static let binBottomInset: CGFloat = 29
    static let badgeX: CGFloat = 71
    static let badgeLandingBottomInset: CGFloat = 24
    static let badgeRestBottomInset: CGFloat = 72
    static let badgeDiameter: CGFloat = 20
    /// The bin leaves this long after the download starts, and the badge a second later.
    static let binLeavesAt: TimeInterval = 2.17
    static let badgeLeavesAt: TimeInterval = 3.2

    /// How far a settling spring still is from rest, from 1 down to 0. Measured: 0.29 s to its 1.5% overshoot.
    static func spring(at time: TimeInterval) -> CGFloat {
        guard time > 0 else { return 1 }
        let stiffness = 18.0, damping = 0.8
        let damped = stiffness * (1 - damping * damping).squareRoot()
        return CGFloat(exp(-damping * stiffness * time) * cos(damped * time))
    }

    static func binX(at time: TimeInterval) -> CGFloat {
        let settled = binRestX - (binRestX + binSize) * spring(at: time)
        guard time > binLeavesAt else { return settled }
        return settled - (binRestX + binSize) * min(CGFloat((time - binLeavesAt) / 0.12), 1)
    }
}

// MARK: - BrowserDownloadFlightView

/// A new download: a badge flies from the pointer into a thumbnail that sits on the archive button for a while.
final class BrowserDownloadFlightView: NSView {
    // MARK: Internal

    static let binSize: CGFloat = 32
    /// How long the thumbnail stays: about 30 s.
    static let binLifetime: TimeInterval = 30

    // MARK: Private

    private static let binPopDuration: TimeInterval = 0.5

    override var isFlipped: Bool { true }

    var onOpen: () -> Void = {}

    private let badge = NSView()
    private let arrow = NSImageView()
    private let bin = NSView()
    private let preview = NSImageView()
    private let sidebarlessBin = NSView()
    private let sidebarlessIcon = NSImageView()
    private let animation = BrowserNativeAnimation()
    private var binCenter = CGPoint.zero
    private var dismissTimer: Timer?
    private var previewTimer: Timer?
    private var swipeTravel: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        badge.layer?.shadowColor = NSColor.black.cgColor
        badge.layer?.shadowOpacity = 0.3
        badge.layer?.shadowRadius = 3
        badge.layer?.shadowOffset = .zero
        arrow.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        arrow.contentTintColor = .white
        arrow.imageScaling = .scaleProportionallyUpOrDown
        badge.addSubview(arrow)
        bin.wantsLayer = true
        bin.layer?.backgroundColor = NSColor.white.cgColor
        bin.layer?.cornerRadius = 7
        bin.layer?.shadowColor = NSColor.black.cgColor
        bin.layer?.shadowOpacity = 0.25
        bin.layer?.shadowRadius = 4
        bin.layer?.shadowOffset = CGSize(width: 0, height: -1)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        bin.addSubview(preview)
        addSubview(bin)
        sidebarlessBin.wantsLayer = true
        sidebarlessBin.layer?.cornerRadius = 12
        sidebarlessBin.isHidden = true
        sidebarlessIcon.image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        sidebarlessIcon.frame = NSRect(
            x: 0,
            y: 0,
            width: BrowserDownloadBinMotion.binSize,
            height: BrowserDownloadBinMotion.binSize,
        )
        sidebarlessBin.addSubview(sidebarlessIcon)
        addSubview(sidebarlessBin)
        addSubview(badge)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let location = convert(point, from: superview)
        return (!bin.isHidden && bin.frame.contains(location))
            || (!sidebarlessBin.isHidden && sidebarlessBin.frame.contains(location)) ? self : nil
    }

    override func mouseDown(with _: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bin.frame.contains(location) || sidebarlessBin.frame.contains(location) {
            dismiss()
            onOpen()
        }
    }

    /// A swipe left puts it away.
    override func scrollWheel(with event: NSEvent) {
        swipeTravel = event.phase == .began ? 0 : swipeTravel + event.scrollingDeltaX
        if swipeTravel < -24 {
            dismiss()
        }
    }

    /// No sidebar, so no archive button: a bin comes in from the window's edge for a moment.
    func launchWithoutSidebar(from source: CGPoint, tint: NSColor, fill: NSColor) {
        previewTimer?.invalidate()
        dismissTimer?.invalidate()
        isHidden = false
        bin.isHidden = true
        badge.isHidden = false
        badge.layer?.borderColor = tint.cgColor
        arrow.contentTintColor = tint
        sidebarlessBin.isHidden = false
        sidebarlessBin.layer?.backgroundColor = fill.cgColor
        sidebarlessIcon.contentTintColor = tint
        let height = bounds.height
        let motion = BrowserDownloadBinMotion.self
        let landing = CGPoint(x: motion.badgeX, y: height - motion.badgeLandingBottomInset)
        let projectile = BrowserDownloadProjectile(source: source, destination: landing)
        let total = motion.badgeLeavesAt
        animation.start(.bezier(total, x1: 0, y1: 0, x2: 1, y2: 1)) { [weak self] progress in
            guard let self else { return }
            let time = progress * total
            sidebarlessBin.frame = CGRect(
                x: motion.binX(at: time),
                y: height - motion.binBottomInset - motion.binSize,
                width: motion.binSize,
                height: motion.binSize,
            )
            guard time >= projectile.duration else {
                let size = max(projectile.diameter(at: time), motion.badgeDiameter)
                placeBadge(center: projectile.center(at: time), size: size, projectile: projectile, time: time)
                return
            }
            let travel = motion.badgeRestBottomInset - motion.badgeLandingBottomInset
            let y = height - motion.badgeRestBottomInset + travel * motion.spring(at: time - projectile.duration)
            placeBadge(
                center: CGPoint(x: motion.badgeX, y: y),
                size: motion.badgeDiameter,
                projectile: projectile,
                time: time,
            )
        } completion: { [weak self] in
            self?.dismiss()
        }
    }

    func launch(
        from source: CGPoint,
        toBinCenter center: CGPoint,
        fileName: String,
        tint: NSColor,
        finishedFile: @escaping @MainActor () -> URL?,
    ) {
        badge.layer?.borderColor = tint.cgColor
        arrow.contentTintColor = tint
        previewTimer?.invalidate()
        dismissTimer?.invalidate()
        isHidden = false
        sidebarlessBin.isHidden = true
        binCenter = center
        preview.image = NSWorkspace.shared.icon(
            for: UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data,
        )
        let projectile = BrowserDownloadProjectile(source: source, destination: center)
        let duration = max(projectile.duration, Self.binPopDuration)
        bin.isHidden = false
        badge.isHidden = false
        animation.start(.bezier(duration, x1: 0, y1: 0, x2: 1, y2: 1)) { [weak self] progress in
            self?.place(projectile, at: progress * duration)
        } completion: { [weak self] in
            self?.badge.isHidden = true
            self?.placeBin(at: .infinity)
        }
        dismissTimer = .scheduledTimer(withTimeInterval: duration + Self.binLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        previewTimer = .scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let url = finishedFile() else { return }
                self.previewTimer?.invalidate()
                self.loadPreview(of: url)
            }
        }
    }

    private func place(_ projectile: BrowserDownloadProjectile, at time: TimeInterval) {
        placeBin(at: time)
        guard time < projectile.duration else {
            badge.isHidden = true
            return
        }
        placeBadge(
            center: projectile.center(at: time),
            size: projectile.diameter(at: time),
            projectile: projectile,
            time: time,
        )
    }

    private func placeBadge(
        center: CGPoint,
        size: CGFloat,
        projectile: BrowserDownloadProjectile,
        time: TimeInterval,
    ) {
        badge.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        badge.layer?.cornerRadius = size / 2
        badge.layer?.borderWidth = size * 0.07
        badge.alphaValue = min(time / 0.05, 1)
        let arrowSize = size * 0.5
        arrow.frame = CGRect(x: (size - arrowSize) / 2, y: (size - arrowSize) / 2, width: arrowSize, height: arrowSize)
        // It points the way it's thrown and straightens as it falls.
        arrow.frameCenterRotation = 0
        arrow.frameCenterRotation = 25 * (1 - min(time / projectile.duration / 0.6, 1))
    }

    /// It grows from the button, dips and settles.
    private func placeBin(at time: TimeInterval) {
        let grow = min(time / 0.08, 1)
        let size = Self.binSize * (0.35 + 0.65 * grow)
        let keys: [(TimeInterval, CGFloat)] = [(0.08, -2), (0.15, 12), (0.3, -1.5), (0.45, 0)]
        var offset: CGFloat = 0
        if time < 0.45 {
            offset = keys[0].1
            for (start, end) in zip(keys, keys.dropFirst()) where time >= start.0 {
                offset = start.1 + (end.1 - start.1) * CGFloat((min(time, end.0) - start.0) / (end.0 - start.0))
            }
        }
        bin.frame = CGRect(x: binCenter.x - size / 2, y: binCenter.y + offset - size / 2, width: size, height: size)
        preview.frame = bin.bounds
    }

    private func loadPreview(of url: URL) {
        let side = Self.binSize
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            if let image = BrowserImageThumbnailer.image(contentsOf: url, maximumPixelSize: side * 2) {
                preview.image = image
            }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .thumbnail,
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async { self?.preview.image = image }
        }
    }

    private func dismiss() {
        dismissTimer?.invalidate()
        previewTimer?.invalidate()
        animation.cancel()
        badge.isHidden = true
        bin.isHidden = true
        sidebarlessBin.isHidden = true
        isHidden = true
    }
}
