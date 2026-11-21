// BrowserMobileHomeLogo.swift

import UIKit

// MARK: - BrowserMobileHomeLogo

/// The app's mark in the middle of the empty backdrop, to play with: a touch
/// lifts it, one finger drags it, two fingers turn and scale it, and letting
/// go springs it back to its place. Each lift and landing taps the haptics.
final class BrowserMobileHomeLogo: UIView, UIGestureRecognizerDelegate {
    // MARK: Internal

    static let width: CGFloat = 150

    private static let liftedScale: CGFloat = 1.2

    override var intrinsicContentSize: CGSize {
        let size = imageView.image?.size ?? CGSize(width: 3, height: 2)
        return CGSize(width: Self.width, height: Self.width * size.height / max(size.width, 1))
    }

    // MARK: Private

    private let imageView = UIImageView()
    private let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let landHaptic = UIImpactFeedbackGenerator(style: .light)
    /// The gestures holding the mark now.
    private var holders = Set<ObjectIdentifier>()
    private var dragStart = CGPoint.zero
    private var offset = CGPoint.zero
    private var pinchScale: CGFloat = 1
    private var turn: CGFloat = 0

    private var activeTouches: Int { holders.count }

    private var home: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.homeLogo"
        isAccessibilityElement = false
        imageView.image = UIImage(named: "HomeLogo")
        imageView.contentMode = .scaleAspectFit
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOffset = CGSize(width: 0, height: 10)
        imageView.layer.shadowRadius = 18
        imageView.layer.shadowOpacity = 0
        addSubview(imageView)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        for gesture in [press, pinch, rotation] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard activeTouches == 0 else { return }
        imageView.bounds = CGRect(origin: .zero, size: bounds.size)
        imageView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        // The mark can be caught wherever it has been dragged to.
        imageView.frame.insetBy(dx: -12, dy: -12).contains(point)
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            begin(gesture)
            dragStart = CGPoint(x: location.x - offset.x, y: location.y - offset.y)
        case .changed:
            offset = CGPoint(x: location.x - dragStart.x, y: location.y - dragStart.y)
            apply()
        case .cancelled, .ended, .failed:
            end(gesture)
        default:
            break
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            begin(gesture)
        case .changed:
            pinchScale = min(max(gesture.scale, 0.5), 2.5)
            apply()
        case .cancelled, .ended, .failed:
            end(gesture)
        default:
            break
        }
    }

    @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            begin(gesture)
        case .changed:
            turn = gesture.rotation
            apply()
        case .cancelled, .ended, .failed:
            end(gesture)
        default:
            break
        }
    }

    private func begin(_ gesture: UIGestureRecognizer) {
        holders.insert(ObjectIdentifier(gesture))
        guard holders.count == 1 else { return }
        liftHaptic.impactOccurred()
        landHaptic.prepare()
        UIView.animate(springDuration: 0.16, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            self.apply()
        }
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = imageView.layer.presentation()?.shadowOpacity ?? 0
        shadow.duration = 0.16
        imageView.layer.shadowOpacity = 0.35
        imageView.layer.add(shadow, forKey: "lift")
    }

    private func end(_ gesture: UIGestureRecognizer) {
        guard holders.remove(ObjectIdentifier(gesture)) != nil, holders.isEmpty else { return }
        offset = .zero
        pinchScale = 1
        turn = 0
        landHaptic.impactOccurred()
        liftHaptic.prepare()
        UIView.animate(springDuration: 0.55, bounce: 0.3, initialSpringVelocity: 0, delay: 0, options: [
            .allowUserInteraction, .beginFromCurrentState,
        ]) {
            self.imageView.center = self.home
            self.imageView.transform = .identity
        }
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = imageView.layer.presentation()?.shadowOpacity ?? 0.35
        shadow.duration = 0.3
        imageView.layer.shadowOpacity = 0
        imageView.layer.add(shadow, forKey: "land")
    }

    private func apply() {
        imageView.center = CGPoint(x: home.x + offset.x, y: home.y + offset.y)
        imageView.transform = CGAffineTransform(rotationAngle: turn)
            .scaledBy(x: Self.liftedScale * pinchScale, y: Self.liftedScale * pinchScale)
    }
}
