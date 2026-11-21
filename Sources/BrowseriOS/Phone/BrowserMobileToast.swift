// BrowserMobileToast.swift

import UIKit

// MARK: - BrowserMobileToast

/// A short message in a blue tile above the bar, such as "Copied URL". It
/// pops in, stays a little under three seconds and drops back into the bar.
final class BrowserMobileToast: UIView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: ceil(label.intrinsicContentSize.width) + 30, height: 49)
    }

    // MARK: Private

    private let gradient = CAGradientLayer()
    private let label = UILabel()
    private var isHiding = false

    // MARK: Internal

    init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "browser.toast"
        gradient.colors = [
            UIColor(red: 74 / 255, green: 84 / 255, blue: 1, alpha: 1).cgColor,
            UIColor(red: 46 / 255, green: 52 / 255, blue: 205 / 255, alpha: 1).cgColor,
        ]
        gradient.cornerRadius = 14
        gradient.cornerCurve = .continuous
        layer.addSublayer(gradient)
        layer.shadowColor = UIColor(red: 60 / 255, green: 70 / 255, blue: 1, alpha: 1).cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 14
        layer.shadowOffset = .zero
        label.text = text
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        label.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 14).cgPath
    }

    /// Shows `text` centred in `host` with its middle `bottomGap` above the
    /// bar's top edge `barTop`; a newer toast replaces an older one.
    @MainActor static func show(_ text: String, in host: UIView, barTop: CGFloat) {
        host.subviews.compactMap { $0 as? BrowserMobileToast }.forEach { $0.hide() }
        let toast = BrowserMobileToast(text: text)
        toast.accessibilityLabel = text
        toast.bounds = CGRect(origin: .zero, size: toast.intrinsicContentSize)
        toast.center = CGPoint(x: host.bounds.midX, y: barTop - 49)
        host.addSubview(toast)
        UIAccessibility.post(notification: .announcement, argument: text)
        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: 18).scaledBy(x: 0.6, y: 0.6)
        UIView.animate(springDuration: 0.3, bounce: 0.25, initialSpringVelocity: 0, delay: 0, options: []) {
            toast.alpha = 1
            toast.transform = .identity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak toast] in toast?.hide() }
    }

    private func hide() {
        guard !isHiding else { return }
        isHiding = true
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 16).scaledBy(x: 0.9, y: 0.9)
        } completion: { _ in
            self.removeFromSuperview()
        }
    }
}
