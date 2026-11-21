// BrowserMobileHomeLogo.swift

import UIKit

// MARK: - BrowserMobileHomeLogo

/// The app's mark in the middle of the empty backdrop, to play with: a touch
/// lifts it, one finger drags it, two fingers turn and scale it, and letting
/// go springs it back to its place. Each lift and landing taps the haptics.
/// A finger moving across the backdrop around it turns it like a wheel; let
/// go while moving and it rolls on to stand upright again, at rest it rolls
/// back. Its light stays put on the screen while it turns.
final class BrowserMobileHomeLogo: UIView, UIGestureRecognizerDelegate {
    // MARK: Internal

    static let width: CGFloat = 150

    private static let liftedScale: CGFloat = 1.2
    /// Angular speed, in radians per second, above which a released wheel
    /// rolls on in its direction instead of back.
    private static let rollOnSpeed: CGFloat = 0.3

    override var intrinsicContentSize: CGSize {
        let size = imageView.image?.size ?? CGSize(width: 3, height: 2)
        return CGSize(width: Self.width, height: Self.width * size.height / max(size.width, 1))
    }

    /// Turns the mark from the backdrop; add it to the view behind the mark.
    let backdropPan = UIPanGestureRecognizer()

    // MARK: Private

    private let imageView = UIImageView()
    /// The light on the mark: clipped to its shape, it turns back against
    /// the mark so it stays fixed on the screen.
    private let sheenClip = UIView()
    private let sheen = BrowserMobileHomeLogoSheen()
    private let liftHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let landHaptic = UIImpactFeedbackGenerator(style: .light)
    /// The gestures holding the mark now.
    private var holders = Set<ObjectIdentifier>()
    private var dragStart = CGPoint.zero
    private var offset = CGPoint.zero
    private var pinchScale: CGFloat = 1
    private var turn: CGFloat = 0
    /// The wheel's turn from the backdrop, in radians.
    private var spin: CGFloat = 0
    private var lastSpinAngle: CGFloat = 0
    private var lastSpinTime: CFTimeInterval = 0
    private var spinVelocity: CGFloat = 0

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
        sheenClip.isUserInteractionEnabled = false
        if let image = imageView.image?.cgImage {
            let mask = CALayer()
            mask.contents = image
            mask.contentsGravity = .resizeAspect
            sheenClip.layer.mask = mask
        }
        sheenClip.addSubview(sheen)
        imageView.addSubview(sheenClip)
        backdropPan.addTarget(self, action: #selector(spun(_:)))
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
        sheenClip.frame = imageView.bounds
        sheenClip.layer.mask?.frame = sheenClip.bounds
        // Large enough to cover the mark at any angle.
        let side = hypot(bounds.width, bounds.height)
        sheen.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sheen.center = CGPoint(x: sheenClip.bounds.midX, y: sheenClip.bounds.midY)
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
            self.apply()
        }
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = imageView.layer.presentation()?.shadowOpacity ?? 0.35
        shadow.duration = 0.3
        imageView.layer.shadowOpacity = 0
        imageView.layer.add(shadow, forKey: "land")
    }

    private func apply() {
        imageView.center = CGPoint(x: home.x + offset.x, y: home.y + offset.y)
        let scale = activeTouches > 0 ? Self.liftedScale * pinchScale : 1
        imageView.transform = CGAffineTransform(rotationAngle: turn + spin).scaledBy(x: scale, y: scale)
        sheen.transform = CGAffineTransform(rotationAngle: -(turn + spin))
    }

    // MARK: Wheel

    @objc private func spun(_ gesture: UIPanGestureRecognizer) {
        guard let host = gesture.view else { return }
        let point = gesture.location(in: host)
        let center = convert(imageView.center, to: host)
        let angle = atan2(point.y - center.y, point.x - center.x)
        let now = CACurrentMediaTime()
        switch gesture.state {
        case .began:
            // Catch a rolling wheel where it is.
            if let presentation = imageView.layer.presentation(),
               imageView.layer.animation(forKey: "roll") != nil
            {
                spin = atan2(presentation.transform.m12, presentation.transform.m11) - turn
            }
            imageView.layer.removeAnimation(forKey: "roll")
            sheen.layer.removeAnimation(forKey: "roll")
            lastSpinAngle = angle
            lastSpinTime = now
            spinVelocity = 0
            apply()
        case .changed:
            var delta = angle - lastSpinAngle
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            // Near the center the angle jumps about; the wheel takes only what a hand could turn.
            let distance = hypot(point.x - center.x, point.y - center.y)
            guard distance > 24 else {
                lastSpinAngle = angle
                return
            }
            spin += delta
            let elapsed = now - lastSpinTime
            if elapsed > 0 {
                // Smooths the speed over the last few moves.
                spinVelocity = spinVelocity * 0.4 + delta / CGFloat(elapsed) * 0.6
            }
            lastSpinAngle = angle
            lastSpinTime = now
            apply()
        case .cancelled, .ended, .failed:
            // A finger that stopped before lifting leaves no speed.
            if now - lastSpinTime > 0.1 { spinVelocity = 0 }
            roll(velocity: spinVelocity)
        default:
            break
        }
    }

    /// Rolls the wheel on to the next upright turn in its direction, or back
    /// to the nearest one when it was let go at rest.
    private func roll(velocity: CGFloat) {
        let full = 2 * CGFloat.pi
        let target: CGFloat =
            if velocity > Self.rollOnSpeed {
                ceil((spin + 0.01) / full) * full
            } else if velocity < -Self.rollOnSpeed {
                floor((spin - 0.01) / full) * full
            } else {
                (spin / full).rounded() * full
            }
        let from = spin - target
        spin = 0
        apply()
        guard abs(from) > 0.001 else { return }
        // Settles without overshoot, as a critically damped spring.
        for (layer, sign) in [(imageView.layer, CGFloat(1)), (sheen.layer, CGFloat(-1))] {
            let animation = CASpringAnimation(keyPath: "transform.rotation.z")
            animation.isAdditive = true
            animation.fromValue = from * sign
            animation.toValue = 0
            animation.mass = 1
            animation.stiffness = 16
            animation.damping = 8
            animation.initialVelocity = -velocity / from
            animation.duration = animation.settlingDuration
            animation.fillMode = .backwards
            layer.add(animation, forKey: "roll")
        }
    }
}

// MARK: - BrowserMobileHomeLogoSheen

/// Light from the top left and shade toward the bottom right.
private final class BrowserMobileHomeLogoSheen: UIView {
    override static var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor(white: 1, alpha: 0.32).cgColor, UIColor(white: 1, alpha: 0).cgColor,
            UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.22).cgColor,
        ]
        gradient.locations = [0.2, 0.45, 0.55, 0.8]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}
