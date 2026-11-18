// BrowserDownloadFlightView.swift

import AppKit

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

/// A new download: a badge flies from the pointer to the archive button. When the
/// download finishes, its file's icon pops up over the button for a moment.
/// None of it takes the pointer, so the button and its tray react as always.
final class BrowserDownloadFlightView: NSView {
    /// Where a flown download stands.
    enum Outcome: Equatable {
        case running
        case completed(URL)
        /// Canceled or failed: nothing to show.
        case ended
    }

    // MARK: Internal

    static let binSize: CGFloat = 32
    /// How long the finished file's icon shows over the button.
    static let popDuration: TimeInterval = 0.3
    static let popFadeDuration: TimeInterval = 0.1

    // MARK: Private

    /// How often a landed badge checks whether its download finished.
    private static let outcomePollInterval: TimeInterval = 0.1

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
    private var outcomeTimer: Timer?
    private var swipeTravel: CGFloat = 0
    private var hasLanded = false
    private var pendingPop: URL?

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
        bin.layer?.shadowColor = NSColor.black.cgColor
        bin.layer?.shadowOpacity = 0.25
        bin.layer?.shadowRadius = 3
        bin.layer?.shadowOffset = CGSize(width: 0, height: -1)
        bin.isHidden = true
        preview.imageScaling = .scaleProportionallyUpOrDown
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

    /// Only the bin that slides in without a sidebar takes clicks; over the archive
    /// button the pointer goes through to the button and its tray.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let location = convert(point, from: superview)
        return !sidebarlessBin.isHidden && sidebarlessBin.frame.contains(location) ? self : nil
    }

    override func mouseDown(with _: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if !sidebarlessBin.isHidden, sidebarlessBin.frame.contains(location) {
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
        outcomeTimer?.invalidate()
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
        tint: NSColor,
        outcome: @escaping @MainActor () -> Outcome,
    ) {
        badge.layer?.borderColor = tint.cgColor
        arrow.contentTintColor = tint
        outcomeTimer?.invalidate()
        isHidden = false
        alphaValue = 1
        sidebarlessBin.isHidden = true
        bin.isHidden = true
        hasLanded = false
        pendingPop = nil
        binCenter = center
        let projectile = BrowserDownloadProjectile(source: source, destination: center)
        let duration = projectile.duration
        badge.isHidden = false
        animation.start(.bezier(duration, x1: 0, y1: 0, x2: 1, y2: 1)) { [weak self] progress in
            self?.place(projectile, at: progress * duration)
        } completion: { [weak self] in
            guard let self else { return }
            badge.isHidden = true
            hasLanded = true
            if let url = pendingPop {
                pop(url)
            } else if outcomeTimer == nil {
                dismiss()
            }
        }
        // The download may finish before the badge lands; the icon then pops as it lands.
        outcomeTimer = .scheduledTimer(withTimeInterval: Self.outcomePollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch outcome() {
                case .running:
                    return
                case .completed(let url):
                    self.stopPolling()
                    if self.hasLanded {
                        self.pop(url)
                    } else {
                        self.pendingPop = url
                    }
                case .ended:
                    self.stopPolling()
                    if self.hasLanded {
                        self.dismiss()
                    }
                }
            }
        }
    }

    /// What a flown download's item says about it; a vanished item counts as ended.
    static func outcome(of item: BrowserDownloadItem?) -> Outcome {
        guard let item else { return .ended }
        switch item.state {
        case .inProgress:
            return .running
        case .completed:
            return item.fileURL.map(Outcome.completed) ?? .ended
        case .canceled,
             .interrupted:
            return .ended
        }
    }

    private func stopPolling() {
        outcomeTimer?.invalidate()
        outcomeTimer = nil
    }

    private func place(_ projectile: BrowserDownloadProjectile, at time: TimeInterval) {
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

    /// The finished file's icon grows from the button, dips, and goes.
    private func pop(_ url: URL) {
        pendingPop = nil
        preview.image = NSWorkspace.shared.icon(forFile: url.path)
        bin.isHidden = false
        bin.alphaValue = 1
        animation.start(.bezier(Self.popDuration, x1: 0, y1: 0, x2: 1, y2: 1)) { [weak self] progress in
            self?.placeBin(at: progress * Self.popDuration)
        } completion: { [weak self] in
            guard let self else { return }
            animation.start(.bezier(Self.popFadeDuration, x1: 0, y1: 0, x2: 1, y2: 1)) { [weak self] progress in
                self?.bin.alphaValue = 1 - progress
            } completion: { [weak self] in
                self?.dismiss()
            }
        }
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

    private func dismiss() {
        stopPolling()
        pendingPop = nil
        animation.cancel()
        badge.isHidden = true
        bin.isHidden = true
        sidebarlessBin.isHidden = true
        isHidden = true
    }
}
