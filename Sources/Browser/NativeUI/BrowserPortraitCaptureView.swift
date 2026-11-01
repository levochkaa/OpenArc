// BrowserPortraitCaptureView.swift

import AppKit

// MARK: - BrowserPortraitCaptureView

/// Capture in Portrait Mode: the page's picture on a colored backdrop. A slider
/// picks the color and the button at the top copies the result.
final class BrowserPortraitCaptureView: NSView {
    // MARK: Internal

    static let size = NSSize(width: 260, height: 219)

    override var isFlipped: Bool { true }

    var onFinish: () -> Void = {}

    private let page: NSImage
    private let button: BrowserActionButton
    private let preview = NSImageView()
    private let slider = BrowserPortraitHueSlider()

    init(pagePNG: Data) {
        self.page = NSImage(data: pagePNG) ?? NSImage()
        self.button = BrowserActionButton(BrowserStrings.captureInPortraitMode) {}
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        button.onAction = { [weak self] in self?.copyResult() }
        addSubview(button)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
        addSubview(preview)
        slider.onChange = { [weak self] in self?.refreshPreview() }
        addSubview(slider)
        refreshPreview()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: 10, y: 10, width: bounds.width - 20, height: 32)
        preview.frame = NSRect(x: 10, y: 50, width: bounds.width - 20, height: 128)
        slider.frame = NSRect(x: 10, y: 182, width: bounds.width - 20, height: 30)
    }

    override func mouseDown(with _: NSEvent) {}

    /// The page centered on the backdrop with a thin frame and rounded corners.
    private static func composed(page: NSImage, backdrop: [NSColor], canvas: NSSize) -> NSImage? {
        guard page.size.width > 0, page.size.height > 0 else { return nil }
        let image = NSImage(size: canvas)
        image.lockFocusFlipped(true)
        NSGradient(colors: backdrop)?.draw(in: NSRect(origin: .zero, size: canvas), angle: 35)
        let scale = min(canvas.width * 0.58 / page.size.width, canvas.height * 0.76 / page.size.height)
        let size = NSSize(width: page.size.width * scale, height: page.size.height * scale)
        let frame = NSRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height,
        )
        let inset = canvas.width * 0.0085
        let radius = canvas.width * 0.02
        NSColor.white.withAlphaComponent(0.4).setFill()
        NSBezierPath(
            roundedRect: frame.insetBy(dx: -inset, dy: -inset),
            xRadius: radius + inset,
            yRadius: radius + inset,
        ).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).addClip()
        page.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        return image
    }

    private func refreshPreview() {
        preview.image = Self.composed(page: page, backdrop: slider.colors, canvas: NSSize(width: 960, height: 512))
    }

    private func copyResult() {
        let width = max(page.size.width * 1.33, 960)
        let canvas = NSSize(width: width, height: width * 128 / 240)
        guard let image = Self.composed(page: page, backdrop: slider.colors, canvas: canvas),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        NotificationCenter.default.post(name: BrowserCaptureToastView.didCopyNotification, object: png)
        onFinish()
    }
}

// MARK: - BrowserPortraitHueSlider

/// A rainbow track between a gray and a black swatch. The knob's position is the
/// backdrop's hue; the swatches give a plain backdrop.
private final class BrowserPortraitHueSlider: NSView {
    // MARK: Internal

    override var isFlipped: Bool { true }

    var onChange: () -> Void = {}

    private var value: CGFloat = 0.85
    private var plain: NSColor?

    var colors: [NSColor] {
        if let plain {
            return [plain, plain.blended(withFraction: 0.2, of: .white) ?? plain]
        }
        let hue = value
        return [
            NSColor(hue: hue, saturation: 0.3, brightness: 0.95, alpha: 1),
            NSColor(hue: hue, saturation: 0.5, brightness: 0.68, alpha: 1),
        ]
    }

    private var track: NSRect { NSRect(x: 32, y: 7, width: max(bounds.width - 64, 0), height: 12) }

    override func draw(_: NSRect) {
        NSColor(white: 0.25, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 5, width: 16, height: 16)).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - 20, y: 5, width: 16, height: 16)).fill()
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map {
            NSColor(hue: $0, saturation: 0.6, brightness: 1, alpha: 1)
        }
        NSGradient(colors: stops)?.draw(
            in: NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6),
            angle: 0,
        )
        NSColor.white.setFill()
        let x = track.minX + track.width * value - 12
        NSBezierPath(ovalIn: NSRect(x: x, y: 1, width: 24, height: 24)).fill()
    }

    override func mouseDown(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }

    private func update(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if x < 24 {
            plain = NSColor(white: 0.25, alpha: 1)
        } else if x > bounds.width - 24 {
            plain = .black
        } else {
            plain = nil
            value = min(max((x - track.minX) / max(track.width, 1), 0), 1)
        }
        needsDisplay = true
        onChange()
    }
}
