// BrowserMobileTabSwitcherView.swift

import UIKit

// MARK: - BrowserMobileTabSwitcherView

/// The phone's tab switcher: tab pictures in an overlapping row, the newest on
/// the right and on top. Swiping sideways moves through them, a tap opens one,
/// flicking one up closes it, and a tap between them goes back to the tab
/// that was open. The bar's Spaces, New Tab and Settings sit over it.
final class BrowserMobileTabSwitcherView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    // MARK: Internal

    struct Entry: Equatable {
        let id: String
        let title: String
        let urlString: String
    }

    /// Room between neighbors to the right of the focused card, as a share of the width.
    static let forwardStep: CGFloat = 0.495
    /// How far the card left of the focused one sits, as a share of the width.
    static let backwardStep: CGFloat = 0.18
    static let newestExtraStep: CGFloat = 0.062
    static let cardWidthShare: CGFloat = 0.644
    static let cornerRadius: CGFloat = 26

    var onOpen: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// A tap outside the cards.
    var onDismiss: (() -> Void)?

    let backdrop = UIImageView()

    private(set) var entries = [Entry]()
    /// Index of the card in the middle, fractional while scrolling.
    private(set) var position: CGFloat = 0

    // MARK: Private

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let dim = UIView()
    private let cardsLayer = UIView()
    private let scroller = UIScrollView()
    private var cards = [String: Card]()
    private weak var liftGesture: UIPanGestureRecognizer?
    private var liftedCard: Card?
    private var liftedID: String?

    var cardSize: CGSize {
        let width = (bounds.width * Self.cardWidthShare).rounded()
        return CGSize(width: width, height: (width * bounds.height / max(bounds.width, 1)).rounded())
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.tabSwitcher"
        backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.13, alpha: 1)
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        addSubview(blur)
        dim.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.13, alpha: 0.86)
        addSubview(dim)
        addSubview(cardsLayer)
        scroller.delegate = self
        scroller.showsHorizontalScrollIndicator = false
        scroller.decelerationRate = .fast
        scroller.alwaysBounceHorizontal = true
        scroller.backgroundColor = .clear
        scroller.isAccessibilityElement = false
        addSubview(scroller)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        scroller.addGestureRecognizer(tap)
        let lift = UIPanGestureRecognizer(target: self, action: #selector(lifted(_:)))
        lift.delegate = self
        scroller.addGestureRecognizer(lift)
        scroller.panGestureRecognizer.require(toFail: lift)
        self.liftGesture = lift
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [backdrop, blur, dim, cardsLayer, scroller] as [UIView] {
            view.frame = bounds
        }
        let step = bounds.width * Self.forwardStep
        scroller.contentSize = CGSize(width: bounds.width + step * CGFloat(max(entries.count - 1, 0)), height: 1)
        if !scroller.isDragging, !scroller.isDecelerating {
            scroller.contentOffset.x = position * step
        }
        layoutCards()
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === liftGesture, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) * 1.2 else { return false }
        return entryIndex(at: pan.location(in: self)) != nil
    }

    /// Replaces the cards, keeping pictures of tabs that stay.
    func setEntries(_ newEntries: [Entry], focus: CGFloat) {
        let ids = Set(newEntries.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards.removeValue(forKey: id)
        }
        entries = newEntries
        for entry in entries {
            let card = cards[entry.id] ?? Card()
            card.show(entry)
            if cards[entry.id] == nil {
                cards[entry.id] = card
                cardsLayer.addSubview(card)
            }
        }
        for entry in entries {
            if let card = cards[entry.id] { cardsLayer.bringSubviewToFront(card) }
        }
        position = clampedPosition(focus)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func card(for id: String) -> Card? { cards[id] }

    func setPicture(_ image: UIImage?, for id: String) { cards[id]?.picture = image }

    func setLivePicture(_ view: UIView?, for id: String) { cards[id]?.livePicture = view }

    func reloadIcons() { cards.values.forEach { $0.reloadIcon() } }

    /// Where a tab's card sits when the row is still at `position`.
    func cardFrame(index: Int, position: CGFloat) -> CGRect {
        let size = cardSize
        let offset = CGFloat(index) - position
        let width = bounds.width
        let focusedX = width * 0.211
        let x: CGFloat
        if offset >= 0 {
            x = focusedX + offset * width * Self.forwardStep
                // The newest card leaves more of the one before it in view.
                + (index == entries.count - 1 ? min(offset, 1) * width * Self.newestExtraStep : 0)
        } else {
            // The older cards bunch up toward the left edge.
            let k: CGFloat = 1.5
            let spread = width * Self.backwardStep / (1 - exp(-k))
            x = focusedX - spread * (1 - exp(k * offset))
        }
        let y = (bounds.height - size.height) / 2 + bounds.height * 0.017
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func cardFrame(for id: String) -> CGRect? {
        entries.firstIndex { $0.id == id }.map { cardFrame(index: $0, position: position) }
    }

    func layoutCards() {
        for (index, entry) in entries.enumerated() {
            guard let card = cards[entry.id], card !== liftedCard, !card.isDetached else { continue }
            let frame = cardFrame(index: index, position: position)
            card.bounds = CGRect(origin: .zero, size: frame.size)
            card.center = CGPoint(x: frame.midX, y: frame.midY)
            let offset = CGFloat(index) - position
            card.titleAlpha = max(0, 1 - abs(offset) * 1.4)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let step = max(bounds.width * Self.forwardStep, 1)
        position = scrollView.contentOffset.x / step
        layoutCards()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>,
    ) {
        let step = max(bounds.width * Self.forwardStep, 1)
        let projected = targetContentOffset.pointee.x / step
        let current = scrollView.contentOffset.x / step
        // One flick moves one card or more, never back toward where it started.
        var target = projected.rounded()
        if velocity.x > 0.2 { target = max(target, current.rounded(.up)) }
        if velocity.x < -0.2 { target = min(target, current.rounded(.down)) }
        targetContentOffset.pointee.x = clampedPosition(target) * step
    }

    private func clampedPosition(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), CGFloat(max(entries.count - 1, 0)))
    }

    /// The topmost card under a point: newer cards cover older ones.
    private func entryIndex(at point: CGPoint) -> Int? {
        for index in entries.indices.reversed() {
            let frame = cardFrame(index: index, position: position)
            let hit = CGRect(x: frame.minX, y: frame.minY - 36, width: frame.width, height: frame.height + 36)
            if hit.contains(point) { return index }
        }
        return nil
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let index = entryIndex(at: gesture.location(in: self)) else {
            onDismiss?()
            return
        }
        onOpen?(entries[index].id)
    }

    @objc private func lifted(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let index = entryIndex(at: gesture.location(in: self)), let card = cards[entries[index].id]
            else { return }
            liftedCard = card
            liftedID = entries[index].id
        case .changed:
            guard let card = liftedCard, let id = liftedID, let frame = cardFrame(for: id) else { return }
            let translation = gesture.translation(in: self).y
            // Pulling down only gives a little.
            let y = translation < 0 ? translation : translation / (1 + translation / 60)
            card.center = CGPoint(x: frame.midX, y: frame.midY + y)
        case .cancelled, .ended, .failed:
            guard let card = liftedCard, let id = liftedID, let frame = cardFrame(for: id) else { return }
            let translation = gesture.translation(in: self).y
            let velocity = gesture.velocity(in: self).y
            liftedCard = nil
            liftedID = nil
            if gesture.state == .ended, velocity < -500 || translation < -frame.height * 0.3 {
                close(card: card, id: id, velocity: velocity)
            } else {
                UIView.animate(
                    withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState],
                ) {
                    card.center = CGPoint(x: frame.midX, y: frame.midY)
                }
            }
        default: break
        }
    }

    private func close(card: Card, id: String, velocity: CGFloat) {
        card.isDetached = true
        let distance = card.center.y + card.bounds.height
        // Keeps the flick's speed until the card is off the screen.
        let duration = min(0.25, max(0.12, Double(distance / max(abs(velocity), 1))))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
            card.center.y = -card.bounds.height / 2 - 40
        } completion: { _ in
            card.removeFromSuperview()
        }
        cards.removeValue(forKey: id)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        // The cards to the left move up to fill the gap: the focus stays on the
        // card that slid into place.
        let newPosition = clampedPosition(position > CGFloat(index) || index == entries.count ? position - 1 : position)
        let step = bounds.width * Self.forwardStep
        UIView.animate(
            withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
        ) {
            self.position = newPosition
            self.layoutCards()
        }
        scroller.contentSize.width = bounds.width + step * CGFloat(max(entries.count - 1, 0))
        scroller.contentOffset.x = newPosition * step
        onClose?(id)
    }
}

// MARK: BrowserMobileTabSwitcherView.Card

extension BrowserMobileTabSwitcherView {
    /// One tab in the switcher: its picture with the site's icon and title above it.
    final class Card: UIView {
        // MARK: Internal

        var isDetached = false

        var picture: UIImage? {
            didSet { updatePicture() }
        }

        var livePicture: UIView? {
            didSet {
                oldValue?.removeFromSuperview()
                if let livePicture {
                    clip.insertSubview(livePicture, aboveSubview: imageView)
                }
                updatePicture()
                setNeedsLayout()
            }
        }

        var titleAlpha: CGFloat = 1 {
            didSet { header.alpha = titleAlpha }
        }

        // MARK: Private

        private let clip = UIView()
        private let imageView = UIImageView()
        private let placeholderIcon = UIImageView()
        private let header = UIView()
        private let icon = UIImageView()
        private let titleLabel = UILabel()
        private var entry: Entry?

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 18
            layer.shadowOffset = CGSize(width: -4, height: 0)
            clip.layer.cornerRadius = BrowserMobileTabSwitcherView.cornerRadius
            clip.layer.cornerCurve = .continuous
            clip.clipsToBounds = true
            clip.backgroundColor = .white
            addSubview(clip)
            imageView.contentMode = .scaleToFill
            clip.addSubview(imageView)
            placeholderIcon.contentMode = .scaleAspectFit
            placeholderIcon.tintColor = .secondaryLabel
            clip.addSubview(placeholderIcon)
            icon.contentMode = .scaleAspectFit
            icon.layer.cornerRadius = 4
            icon.layer.cornerCurve = .continuous
            icon.clipsToBounds = true
            titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            titleLabel.textColor = .white
            header.addSubview(icon)
            header.addSubview(titleLabel)
            addSubview(header)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            clip.frame = bounds
            layer.shadowPath = UIBezierPath(
                roundedRect: bounds, cornerRadius: BrowserMobileTabSwitcherView.cornerRadius,
            ).cgPath
            layoutPicture()
            header.frame = CGRect(x: 6, y: -32, width: bounds.width - 6, height: 24)
            icon.frame = CGRect(x: 0, y: 2, width: 20, height: 20)
            titleLabel.frame = CGRect(x: 28, y: 0, width: header.bounds.width - 28, height: 24)
            placeholderIcon.frame = CGRect(x: bounds.midX - 24, y: bounds.height * 0.32, width: 48, height: 48)
        }

        func show(_ entry: Entry) {
            self.entry = entry
            let title = entry.title.isEmpty
                ? BrowserMobileFavicons.host(forPage: entry.urlString) ?? String(localized: "New Tab", table: "Mobile")
                : entry.title
            titleLabel.text = title
            accessibilityLabel = title
            accessibilityIdentifier = "browser.tabCard." + entry.id
            reloadIcon()
        }

        func reloadIcon() {
            let image = BrowserMobileFavicons.shared.iconOnDark(forPage: entry?.urlString)
            icon.image = image ?? UIImage(systemName: "globe")
            icon.tintColor = .white
            placeholderIcon.image = image ?? UIImage(systemName: "globe")
        }

        private func updatePicture() {
            imageView.image = picture
            imageView.isHidden = livePicture != nil || picture == nil
            placeholderIcon.isHidden = livePicture != nil || picture != nil
            layoutPicture()
        }

        /// Pictures fill the card's width from the top; a short picture leaves
        /// white below, as a page shorter than the screen does.
        private func layoutPicture() {
            if let livePicture {
                let scale = bounds.width / max(livePicture.bounds.width, 1)
                livePicture.transform = CGAffineTransform(scaleX: scale, y: scale)
                livePicture.center = CGPoint(x: bounds.midX, y: livePicture.bounds.height * scale / 2)
            }
            guard let picture, picture.size.width > 0 else { return }
            imageView.frame = CGRect(
                x: 0, y: 0, width: bounds.width, height: bounds.width * picture.size.height / picture.size.width,
            )
        }
    }
}
