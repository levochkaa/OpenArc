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
        /// A private tab, which shows eyes before its title.
        var isPrivate = false
    }

    /// Room between neighbors to the right of the focused card, as a share of the width.
    static let forwardStep: CGFloat = 0.495
    /// How far the card left of the focused one sits, as a share of the width.
    static let backwardStep: CGFloat = 0.18
    static let newestExtraStep: CGFloat = 0.062
    static let cardHeightShare: CGFloat = 0.65
    /// How much smaller each older card is than the one in the middle, up to two back.
    static let olderCardShrink: CGFloat = 0.014
    static let cornerRadius: CGFloat = 26

    var onOpen: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// A tap outside the cards.
    var onDismiss: (() -> Void)?

    /// The app's backdrop behind the cards.
    let backdrop = BrowserMobileAppBackdrop()

    private(set) var entries = [Entry]()
    /// Index of the card in the middle, fractional while scrolling.
    private(set) var position: CGFloat = 0

    /// The page's side insets on screen, such as the strip beside the
    /// camera on iPhone Duo; card pictures leave them out.
    var pageSideInsets: (left: CGFloat, right: CGFloat) = (0, 0) {
        didSet { cards.values.forEach(applyCrop) }
    }

    /// The status bar's strip above the page, which the tabs' pictures
    /// include and their cards leave out at rest.
    var pageTopInset: CGFloat = 0 {
        didSet {
            cards.values.forEach(applyCrop)
            setNeedsLayout()
        }
    }

    // MARK: Private

    private let cardsLayer = UIView()
    private let scroller = UIScrollView()
    private var cards = [String: Card]()
    private weak var liftGesture: UIPanGestureRecognizer?
    private var liftedCard: Card?
    private var liftedID: String?
    /// Brings the row to rest on a card after a flick, faster than the
    /// scroll view's own deceleration.
    private var settleLink: CADisplayLink?
    private var settle: (start: CGFloat, target: CGFloat, velocity: CGFloat, began: CFTimeInterval)?

    var cardSize: CGSize {
        // A card is the page below the status bar, as wide as that is for
        // its height.
        let height = (bounds.height * Self.cardHeightShare).rounded()
        let pageHeight = max(bounds.height - pageTopInset, 1)
        return CGSize(width: (height * bounds.width / pageHeight).rounded(), height: height)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "browser.tabSwitcher"
        backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.13, alpha: 1)
        addSubview(backdrop)
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
        for view in [backdrop, cardsLayer, scroller] as [UIView] {
            view.frame = bounds
        }
        cards.values.forEach(applyCrop)
        let step = bounds.width * Self.forwardStep
        scroller.contentSize = CGSize(width: bounds.width + step * CGFloat(max(entries.count - 1, 0)), height: 1)
        if !scroller.isDragging, !scroller.isDecelerating, settle == nil {
            scroller.contentOffset.x = position * step
        }
        layoutCards()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopSettle() }
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
            applyCrop(card)
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
        // At either end of the row the focused card sits in the middle; between
        // the ends it moves right to show the older card behind it.
        let lastIndex = CGFloat(max(entries.count - 1, 0))
        let between = min(max(position, 0), 1) * min(max(lastIndex - position, 0), 1)
        let centeredX = (width - size.width) / 2
        let focusedX = centeredX + (width * 0.211 - centeredX) * between
        let x: CGFloat
        if offset >= 0 {
            x = focusedX + offset * width * Self.forwardStep
                // The newest card leaves more of the one before it in view.
                + (index == entries.count - 1 ? min(offset, 1) * between * width * Self.newestExtraStep : 0)
        } else {
            // The older cards bunch up toward the left edge, closer still at the row's end.
            let k: CGFloat = 1.16
            let spread = width * Self.backwardStep * (0.76 + 0.24 * between) / (1 - exp(-k))
            x = focusedX - spread * (1 - exp(k * offset))
        }
        let y = (bounds.height - size.height) / 2 + bounds.height * 0.0157
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        // Older cards recede a little into the stack: their left edges keep
        // their places in the row, their middles stay level.
        let shrink = 1 - Self.olderCardShrink * min(max(-offset, 0), 2)
        return CGRect(
            x: frame.minX, y: frame.minY + frame.height * (1 - shrink) / 2,
            width: frame.width * shrink, height: frame.height * shrink,
        )
    }

    /// Moves cards into `host`, a view over the ones above the switcher, so
    /// a flight to or from the tab stack passes over the bar.
    func lift(_ lifted: [Card], into host: UIView) {
        for card in lifted {
            host.addSubview(card)
        }
    }

    /// Brings lifted cards back among the others, in the row's order.
    func restoreLiftedCards() {
        for entry in entries {
            if let card = cards[entry.id] { cardsLayer.addSubview(card) }
        }
        layoutCards()
    }

    func cardFrame(for id: String) -> CGRect? {
        entries.firstIndex { $0.id == id }.map { cardFrame(index: $0, position: position) }
    }

    /// Places the cards of the tabs `includes` picks, all of them by default.
    func layoutCards(where includes: (String) -> Bool = { _ in true }) {
        for (index, entry) in entries.enumerated() where includes(entry.id) {
            guard let card = cards[entry.id], card !== liftedCard, !card.isDetached else { continue }
            let frame = cardFrame(index: index, position: position)
            card.bounds = CGRect(origin: .zero, size: frame.size)
            card.center = CGPoint(x: frame.midX, y: frame.midY)
            let offset = CGFloat(index) - position
            // The neighbors keep their icons; only the middle card shows its title,
            // which ends before the next card's icon.
            // Older cards' icons fade into the stack and the cards darken;
            // the newer ones stay bright.
            card.titleAlpha = offset < 0 ? max(0, 1 - 0.32 * -offset) : min(1, max(0, 2 - offset))
            card.nameAlpha = max(0, 1 - abs(offset) * 1.4)
            card.depthDim = 0.17 * min(max(-offset, 0), 2)
            card.titleRoom = index + 1 < entries.count
                ? cardFrame(index: index + 1, position: position).minX - frame.minX
                : nil
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
        let targetX = clampedPosition(target) * step
        let x = scrollView.contentOffset.x
        let maxX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
        // Past either end the scroll view bounces back on its own.
        guard x >= 0, x <= maxX else {
            targetContentOffset.pointee.x = targetX
            return
        }
        targetContentOffset.pointee.x = x
        startSettle(from: x, to: targetX, velocity: velocity.x * 1000)
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        stopSettle()
    }

    private func applyCrop(_ card: Card) {
        card.crop = Card.Crop(
            left: pageSideInsets.left, right: pageSideInsets.right, top: pageTopInset,
            screenWidth: bounds.width, restingWidth: cardSize.width,
        )
    }

    /// A critically damped spring from the flick's speed to the card's place.
    private func startSettle(from start: CGFloat, to target: CGFloat, velocity: CGFloat) {
        stopSettle()
        settle = (start, target, velocity, CACurrentMediaTime())
        let link = CADisplayLink(target: self, selector: #selector(settleStep))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        settleLink = link
    }

    private func stopSettle() {
        settleLink?.invalidate()
        settleLink = nil
        settle = nil
    }

    @objc private func settleStep() {
        guard let settle else { return }
        let omega: CGFloat = 20
        let t = CGFloat(CACurrentMediaTime() - settle.began)
        let distance = settle.start - settle.target
        let decay = exp(-omega * t)
        let x = settle.target + (distance + (settle.velocity + omega * distance) * t) * decay
        let speed = (settle.velocity - (settle.velocity + omega * distance) * omega * t) * decay
        if abs(x - settle.target) < 0.5, abs(speed) < 10 {
            scroller.contentOffset.x = settle.target
            stopSettle()
        } else {
            scroller.contentOffset.x = x
        }
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
        let duration = min(0.16, max(0.1, Double(distance / max(abs(velocity), 1))))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
            card.center.y = -card.bounds.height / 2 - 40
        } completion: { _ in
            card.removeFromSuperview()
        }
        cards.removeValue(forKey: id)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        // The cards to the left move up to fill the gap while the card is
        // still leaving: the focus stays on the card that slid into place.
        let newPosition = clampedPosition(position > CGFloat(index) || index == entries.count ? position - 1 : position)
        let step = bounds.width * Self.forwardStep
        UIView.animate(
            springDuration: 0.16, bounce: 0, initialSpringVelocity: 0, delay: 0,
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
        /// What of the page's width the picture leaves out at each side,
        /// fully once the card is at rest and none while it fills the screen.
        struct Crop: Equatable {
            var left: CGFloat = 0
            var right: CGFloat = 0
            var top: CGFloat = 0
            var screenWidth: CGFloat = 0
            var restingWidth: CGFloat = 0
        }

        // MARK: Private

        /// The icon's distance from the card's left edge.
        private static let headerInset: CGFloat = 18

        // MARK: Internal

        var isDetached = false

        var picture: UIImage? {
            didSet { updatePicture() }
        }

        var crop = Crop() {
            didSet {
                if crop != oldValue { setNeedsLayout() }
            }
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

        /// The title's alpha within the header; the icon stays.
        var nameAlpha: CGFloat = 1 {
            didSet { titleLabel.alpha = nameAlpha }
        }

        /// How far right of this card the next one starts, if there is one.
        var titleRoom: CGFloat? {
            didSet {
                if titleRoom != oldValue {
                    setNeedsLayout()
                }
            }
        }

        /// How much darker an older card is than the one in the middle.
        var depthDim: CGFloat = 0 {
            didSet { dim.alpha = depthDim }
        }

        private let clip = UIView()
        private let dim = UIView()
        private let imageView = UIImageView()
        private let placeholderIcon = UIImageView()
        private let header = UIView()
        private let icon = UIImageView()
        private let privateGlyph = UIImageView(image: UIImage(
            systemName: "eyes", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium),
        ))
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
            dim.backgroundColor = .black
            dim.alpha = 0
            dim.isUserInteractionEnabled = false
            clip.addSubview(dim)
            icon.contentMode = .scaleAspectFit
            icon.layer.cornerRadius = 4
            icon.layer.cornerCurve = .continuous
            icon.clipsToBounds = true
            titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
            titleLabel.textColor = .white
            privateGlyph.tintColor = UIColor(white: 1, alpha: 0.75)
            privateGlyph.contentMode = .center
            privateGlyph.isHidden = true
            header.addSubview(icon)
            header.addSubview(privateGlyph)
            header.addSubview(titleLabel)
            addSubview(header)
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layoutSubviews() {
            super.layoutSubviews()
            clip.frame = bounds
            dim.frame = clip.bounds
            layer.shadowPath = UIBezierPath(
                roundedRect: bounds, cornerRadius: BrowserMobileTabSwitcherView.cornerRadius,
            ).cgPath
            layoutPicture()
            header.frame = CGRect(x: Self.headerInset, y: -29, width: bounds.width - Self.headerInset, height: 20)
            icon.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
            // A private tab's eyes sit between the icon and the title.
            let titleX: CGFloat = privateGlyph.isHidden ? 26 : 26 + 24
            privateGlyph.frame = CGRect(x: 26, y: 0, width: 20, height: 20)
            var titleWidth = header.bounds.width - titleX - 10
            if let titleRoom {
                // 4 points short of the next card's icon.
                titleWidth = min(titleWidth, titleRoom - titleX - 4)
            }
            titleLabel.frame = CGRect(x: titleX, y: -2, width: max(titleWidth, 0), height: 24)
            placeholderIcon.frame = CGRect(x: bounds.midX - 24, y: bounds.height * 0.32, width: 48, height: 48)
        }

        func show(_ entry: Entry) {
            self.entry = entry
            let title = entry.title.isEmpty
                ? BrowserMobileFavicons.host(forPage: entry.urlString) ?? String(localized: "New Tab", table: "Mobile")
                : entry.title
            titleLabel.text = title
            privateGlyph.isHidden = !entry.isPrivate
            accessibilityLabel = entry.isPrivate
                ? String(localized: "\(title), Incognito", table: "Mobile")
                : title
            accessibilityIdentifier = "browser.tabCard." + entry.id
            setNeedsLayout()
            reloadIcon()
        }

        func reloadIcon() {
            let image = BrowserMobileFavicons.shared.iconOnDark(forPage: entry?.urlString)
            // A site without an icon gets a faint square in its place.
            icon.image = image
            icon.backgroundColor = image == nil ? UIColor(white: 1, alpha: 0.15) : .clear
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
            // The share of the side insets cut off grows as the card shrinks
            // from the screen's width to its resting width.
            let range = crop.screenWidth - crop.restingWidth
            let cut = range > 0 ? min(max((crop.screenWidth - bounds.width) / range, 0), 1) : 1
            let left = crop.left * cut
            let right = crop.right * cut
            if let livePicture {
                let pageWidth = max(livePicture.bounds.width, 1)
                let scale = bounds.width / max(pageWidth - left - right, 1)
                livePicture.transform = CGAffineTransform(scaleX: scale, y: scale)
                livePicture.center = CGPoint(
                    x: (pageWidth / 2 - left) * scale, y: (livePicture.bounds.height / 2 - crop.top * cut) * scale,
                )
            }
            guard let picture, picture.size.width > 0 else { return }
            let pageWidth = crop.screenWidth > 0 ? crop.screenWidth : bounds.width
            let scale = bounds.width / max(pageWidth - left - right, 1)
            let width = pageWidth * scale
            imageView.frame = CGRect(
                x: -left * scale, y: -crop.top * cut * scale,
                width: width, height: width * picture.size.height / picture.size.width,
            )
        }
    }
}
