// BrowserMobileHomeLogo.swift

import UIKit

// MARK: - BrowserMobileHomeLogo

/// The app's mark in the middle of the empty backdrop, to play with: a touch
/// lifts it, one finger drags it, two fingers turn and scale it, and letting
/// go springs it back to its place. Each lift and landing taps the haptics.
/// A finger moving across the backdrop beside it turns it like a wheel under
/// a hand; let go while moving and it coasts on, slowing down, to stand
/// upright again, at rest it rolls back. Its colors and light stay put on the
/// screen while it turns.
final class BrowserMobileHomeLogo: UIView, UIGestureRecognizerDelegate {
    /// The rim a finger turns the wheel at: wherever it moves, its speed
    /// across the line to the center turns the wheel as if it held this rim.
    static let wheelRadius: CGFloat = 75

    // MARK: Internal

    private static let liftedScale: CGFloat = 1.2
    /// Angular speed, in radians per second, above which a released wheel
    /// rolls on in its direction instead of back.
    private static let rollOnSpeed: CGFloat = 0.3
    /// How long a flung wheel's speed takes to fall by e, in seconds: it
    /// lands on the upright turn nearest to where this carries it.
    private static let coast: CGFloat = 0.48
    /// The turn left, in radians, at which a coasting wheel stops.
    private static let restingTurn: CGFloat = 0.004

    override var intrinsicContentSize: CGSize { BrowserMobileHomeLogoMark.size }

    /// Turns the mark from the backdrop; add it to the view behind the mark.
    let backdropPan = UIPanGestureRecognizer()

    // MARK: Private

    private let mark = BrowserMobileHomeLogoMark()
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
    private var lastSpinPoint = CGPoint.zero

    private var activeTouches: Int { holders.count }

    private var home: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.homeLogo"
        isAccessibilityElement = false
        mark.layer.shadowColor = UIColor.black.cgColor
        mark.layer.shadowOffset = CGSize(width: 0, height: 10)
        mark.layer.shadowRadius = 18
        mark.layer.shadowOpacity = 0
        addSubview(mark)
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
        mark.bounds = CGRect(origin: .zero, size: BrowserMobileHomeLogoMark.size)
        mark.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        // The mark can be caught wherever it has been dragged to.
        mark.frame.insetBy(dx: -12, dy: -12).contains(point)
    }

    /// How far, in radians, a finger at `point` moving by `move` turns a
    /// wheel centered at `center`. Moving straight down beside the mark
    /// turns it as much as moving along its rim.
    static func wheelTurn(at point: CGPoint, moving move: CGVector, around center: CGPoint) -> CGFloat {
        let offset = CGVector(dx: point.x - center.x, dy: point.y - center.y)
        let distance = hypot(offset.dx, offset.dy)
        // Over the center the direction to it means nothing.
        guard distance > 8 else { return 0 }
        return (offset.dx * move.dy - offset.dy * move.dx) / distance / wheelRadius
    }

    /// The upright turn a wheel at `spin` let go at `velocity` lands on, and
    /// whether it coasts there, rather than settling back as a spring.
    static func landing(spin: CGFloat, velocity: CGFloat) -> (turn: CGFloat, coasts: Bool) {
        let full = 2 * CGFloat.pi
        guard abs(velocity) > rollOnSpeed else { return ((spin / full).rounded() * full, false) }
        let turn = ((spin + velocity * coast) / full).rounded() * full
        // Too weak a fling to reach the next upright ahead falls back.
        return (turn, (turn - spin) * velocity > 0)
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
        shadow.fromValue = mark.layer.presentation()?.shadowOpacity ?? 0
        shadow.duration = 0.16
        mark.layer.shadowOpacity = 0.35
        mark.layer.add(shadow, forKey: "lift")
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
        shadow.fromValue = mark.layer.presentation()?.shadowOpacity ?? 0.35
        shadow.duration = 0.3
        mark.layer.shadowOpacity = 0
        mark.layer.add(shadow, forKey: "land")
    }

    private func apply() {
        mark.center = CGPoint(x: home.x + offset.x, y: home.y + offset.y)
        let scale = activeTouches > 0 ? Self.liftedScale * pinchScale : 1
        mark.transform = CGAffineTransform(rotationAngle: turn + spin).scaledBy(x: scale, y: scale)
        mark.holdLight(at: turn + spin)
    }

    // MARK: Wheel

    @objc private func spun(_ gesture: UIPanGestureRecognizer) {
        guard let host = gesture.view else { return }
        let point = gesture.location(in: host)
        let center = convert(mark.center, to: host)
        switch gesture.state {
        case .began:
            // Catch a rolling wheel where it is.
            if let presentation = mark.layer.presentation(), mark.layer.animation(forKey: "roll") != nil {
                spin = atan2(presentation.transform.m12, presentation.transform.m11) - turn
            }
            for (layer, _) in mark.turningLayers {
                layer.removeAnimation(forKey: "roll")
            }
            lastSpinPoint = point
            apply()
        case .changed:
            let move = CGVector(dx: point.x - lastSpinPoint.x, dy: point.y - lastSpinPoint.y)
            spin += Self.wheelTurn(at: point, moving: move, around: center)
            lastSpinPoint = point
            apply()
        case .cancelled, .ended, .failed:
            let velocity = gesture.velocity(in: host)
            roll(velocity: Self.wheelTurn(
                at: point,
                moving: CGVector(dx: velocity.x, dy: velocity.y),
                around: center,
            ))
        default:
            break
        }
    }

    /// Coasts the wheel on, slowing down, to the upright turn its speed
    /// carries it to, or rolls it back to the nearest one when it was let go
    /// at rest.
    private func roll(velocity: CGFloat) {
        let landing = Self.landing(spin: spin, velocity: velocity)
        let from = spin - landing.turn
        spin = 0
        apply()
        guard abs(from) > 0.001 else { return }
        // A flung wheel's speed falls exponentially, at the rate that spends
        // the whole turn left by the time it stops.
        let decay = min(max(-from / velocity, 0.25), 1.2)
        let duration = Double(decay * log(abs(from) / Self.restingTurn))
        let steps = max(Int(duration * 60), 2)
        for (layer, sign) in mark.turningLayers {
            let animation: CAPropertyAnimation
            if landing.coasts {
                let coast = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                coast.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
                coast.values = (0...steps).map { step in
                    step == steps ? 0 : sign * from * exp(-CGFloat(Double(step) / Double(steps) * duration) / decay)
                }
                coast.duration = duration
                animation = coast
            } else {
                // Settles without overshoot, as a critically damped spring.
                let rate: CGFloat = 4
                let spring = CASpringAnimation(keyPath: "transform.rotation.z")
                spring.fromValue = sign * from
                spring.toValue = 0
                spring.mass = 1
                spring.stiffness = rate * rate
                spring.damping = 2 * rate
                spring.initialVelocity = -velocity / from
                spring.duration = spring.settlingDuration
                animation = spring
            }
            animation.isAdditive = true
            animation.fillMode = .backwards
            layer.add(animation, forKey: "roll")
        }
    }
}

// MARK: - BrowserMobileHomeLogoMark

/// The mark as a sticker: an arch over a shorter leg, each filled with its
/// own colors, in a dark outline. The colors run from the top left to the
/// bottom right of the screen, and a light catches the edges facing the top
/// left, whichever way the mark is turned.
final class BrowserMobileHomeLogoMark: UIView {
    // MARK: Internal

    static let width: CGFloat = 150
    static let size = CGSize(width: width, height: (pieceBounds.height * scale + 2 * edge).rounded())

    // MARK: Private

    private static let outline: CGFloat = 4.5
    /// A faint rim outside the outline.
    private static let ring: CGFloat = 2.5
    private static let edge = outline + ring
    /// How far the light reaches in from an edge facing it.
    private static let shine: CGFloat = 1.2

    /// The shapes as drawn in mark.py, in a 1020 x 600 box.
    private static let legData =
        "M 195,300 C 220.8,257.4 278.9,225.0 330,225 C 359.5,225.0 453.0,257.2 453,282 "
            + "C 453.0,288.1 431.4,300.8 424,313 L 273.76,557.63 Q 268,567 257.00,567.00 L 44.00,567.00 "
            + "Q 33,567 38.71,557.60 Z"
    private static let archData =
        "M 584,300 C 537.8,223.9 447.6,165.0 360,165 C 325.2,165.0 305.2,170.0 273,178 "
            + "C 313.0,89.1 408.1,26.0 508,26 C 615.1,26.0 684.6,80.1 738,168 L 975.28,557.61 "
            + "Q 981,567 970.00,567.00 L 757.00,567.00 Q 746,567 740.29,557.60 Z"

    private static let rawLeg = path(legData)
    private static let rawArch = path(archData)
    private static let pieceBounds = rawLeg.boundingBoxOfPath.union(rawArch.boundingBoxOfPath)
    private static let scale = (width - 2 * edge) / pieceBounds.width
    private static let placement = CGAffineTransform(
        translationX: edge - pieceBounds.minX * scale,
        y: edge - pieceBounds.minY * scale,
    ).scaledBy(x: scale, y: scale)

    private static let leg = rawLeg.copy(using: [placement]) ?? rawLeg
    private static let arch = rawArch.copy(using: [placement]) ?? rawArch
    private static let pieces: CGPath = {
        let path = CGMutablePath()
        path.addPath(leg)
        path.addPath(arch)
        return path
    }()

    /// Coral through red to raspberry, and sky through blue to violet.
    private static let archColors = [
        UIColor(red: 1, green: 0.62, blue: 0.42, alpha: 1),
        UIColor(red: 0.96, green: 0.3, blue: 0.39, alpha: 1),
        UIColor(red: 0.8, green: 0.19, blue: 0.5, alpha: 1),
    ]
    private static let legColors = [
        UIColor(red: 0.37, green: 0.62, blue: 1, alpha: 1),
        UIColor(red: 0.28, green: 0.34, blue: 0.94, alpha: 1),
        UIColor(red: 0.36, green: 0.2, blue: 0.77, alpha: 1),
    ]

    /// Views that stay put on the screen while the mark turns.
    private var held = [UIView]()
    /// Turns the light's offset back into the mark's turn.
    private let shiftedTurn = UIView()

    /// The layers that turn as the mark does, and the sign of their turn:
    /// the colors and light turn back against it.
    var turningLayers: [(CALayer, CGFloat)] {
        [(layer, 1)] + held.map { ($0.layer, -1) } + [(shiftedTurn.layer, 1)]
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: frame.origin, size: Self.size))
        isUserInteractionEnabled = false
        let bounds = CGRect(origin: .zero, size: Self.size)
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = hypot(bounds.width, bounds.height)
        let ring = BrowserMobileHomeLogoShape(path: Self.pieces)
        ring.shape.fillColor = UIColor(white: 1, alpha: 0.1).cgColor
        ring.shape.strokeColor = ring.shape.fillColor
        ring.shape.lineWidth = 2 * Self.edge
        ring.shape.lineJoin = .round
        let outline = BrowserMobileHomeLogoShape(path: Self.pieces)
        outline.shape.fillColor = UIColor(red: 0.11, green: 0.1, blue: 0.1, alpha: 1).cgColor
        outline.shape.strokeColor = outline.shape.fillColor
        outline.shape.lineWidth = 2 * Self.outline
        outline.shape.lineJoin = .round
        var layers: [UIView] = [ring, outline]
        for (piece, colors) in [(Self.leg, Self.legColors), (Self.arch, Self.archColors)] {
            let clip = UIView(frame: bounds)
            let mask = CAShapeLayer()
            mask.path = piece
            clip.layer.mask = mask
            let gradient = BrowserMobileHomeLogoGradient(colors: colors)
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.center = middle
            clip.addSubview(gradient)
            held.append(gradient)
            layers.append(clip)
        }
        let grain = UIView(frame: bounds)
        grain.backgroundColor = BrowserMobileHomeLogoGrain.color
        let grainMask = CAShapeLayer()
        grainMask.path = Self.pieces
        grain.layer.mask = grainMask
        layers.append(grain)
        // The light: the shapes less themselves moved away from it, which
        // leaves the edges facing it. The move turns back against the mark,
        // so it always points away from the top left of the screen.
        let light = BrowserMobileHomeLogoShape(path: Self.pieces)
        light.shape.fillColor = UIColor(white: 1, alpha: 0.6).cgColor
        let shade = UIView(frame: bounds)
        let heldTurn = UIView()
        let shift = UIView()
        let away = CGMutablePath()
        away.addRect(bounds.insetBy(dx: -20, dy: -20))
        away.addPath(Self.pieces)
        let moved = BrowserMobileHomeLogoShape(path: away)
        moved.shape.fillRule = .evenOdd
        for view in [heldTurn, shift, shiftedTurn, moved] {
            view.bounds = bounds
            view.center = middle
        }
        shift.transform = CGAffineTransform(translationX: Self.shine, y: Self.shine)
        shiftedTurn.addSubview(moved)
        shift.addSubview(shiftedTurn)
        heldTurn.addSubview(shift)
        shade.addSubview(heldTurn)
        held.append(heldTurn)
        light.mask = shade
        layers.append(light)
        for view in layers {
            view.frame = bounds
            addSubview(view)
        }
        layer.shadowPath = Self.pieces.union(Self.pieces.copy(
            strokingWithWidth: 2 * Self.edge,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 1,
        ))
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A path from SVG path data that uses only absolute M, L, Q, C and Z.
    static func path(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var command: Character = "M"
        var numbers = [CGFloat]()
        for token in data.split(whereSeparator: { $0 == " " || $0 == "," }) {
            if let letter = token.first, letter.isLetter {
                command = letter
                numbers.removeAll()
                if letter == "Z" { path.closeSubpath() }
                continue
            }
            numbers.append(CGFloat(Double(token) ?? 0))
            let points = stride(from: 0, to: numbers.count - 1, by: 2).map {
                CGPoint(x: numbers[$0], y: numbers[$0 + 1])
            }
            switch (command, numbers.count) {
            case ("M", 2): path.move(to: points[0])
            case ("L", 2): path.addLine(to: points[0])
            case ("Q", 4): path.addQuadCurve(to: points[1], control: points[0])
            case ("C", 6): path.addCurve(to: points[2], control1: points[0], control2: points[1])
            default: continue
            }
            numbers.removeAll()
        }
        return path
    }

    /// Keeps the colors and light where they are on the screen with the
    /// mark turned by `angle`.
    func holdLight(at angle: CGFloat) {
        for view in held {
            view.transform = CGAffineTransform(rotationAngle: -angle)
        }
        shiftedTurn.transform = CGAffineTransform(rotationAngle: angle)
    }
}

// MARK: - BrowserMobileHomeLogoShape

/// A view that draws one path.
private final class BrowserMobileHomeLogoShape: UIView {
    override static var layerClass: AnyClass { CAShapeLayer.self }

    var shape: CAShapeLayer { layer as? CAShapeLayer ?? CAShapeLayer() }

    init(path: CGPath) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        shape.path = path
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - BrowserMobileHomeLogoGradient

/// Colors from the top left to the bottom right, across the middle of the
/// square the mark turns in.
private final class BrowserMobileHomeLogoGradient: UIView {
    override static var layerClass: AnyClass { CAGradientLayer.self }

    init(colors: [UIColor]) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = colors.map(\.cgColor)
        gradient.locations = [0.22, 0.5, 0.78]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - BrowserMobileHomeLogoGrain

/// Fine light and dark speckles, as on printed paper.
private enum BrowserMobileHomeLogoGrain {
    static let color: UIColor = {
        let side = 96
        var generator = SystemRandomNumberGenerator()
        // Premultiplied white or black at a random strength.
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0..<side * side {
            let alpha = UInt8.random(in: 0...34, using: &generator)
            let value = Bool.random(using: &generator) ? alpha : 0
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
              )
        else { return .clear }
        return UIColor(patternImage: UIImage(cgImage: image, scale: 3, orientation: .up))
    }()
}
