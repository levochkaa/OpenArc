// BrowserBoostStyle.swift

import Foundation

// MARK: - BrowserBoostColors

/// How a Boost changes a page's colors: a tint picked on the color wheel,
/// lightness turned around, and the contrast, brightness and original
/// saturation sliders.
struct BrowserBoostColors: Codable, Equatable {
    /// Two colors on the wheel: the light one the page's light parts take, and
    /// the dark one, at a hue offset from it, its dark parts take.
    struct Tint: Codable, Equatable {
        static let defaultSecondaryHueOffset: Double = 30

        /// Degrees around the wheel, 0 at its right edge, growing clockwise.
        var hue: Double
        /// From 0 at the wheel's middle to 1 at its edge.
        var saturation: Double
        var secondaryHueOffset: Double

        var secondaryHue: Double {
            BrowserBoostColors.normalizedHue(hue + secondaryHueOffset)
        }

        init(hue: Double, saturation: Double, secondaryHueOffset: Double = Self.defaultSecondaryHueOffset) {
            self.hue = BrowserBoostColors.normalizedHue(hue)
            self.saturation = min(max(saturation, 0), 1)
            self.secondaryHueOffset = secondaryHueOffset
        }

        /// The tint's color for a lightness of the page, from 0 (black) to 1 (white).
        func rgb(atLightness lightness: Double) -> (red: Double, green: Double, blue: Double) {
            let t = min(max(lightness, 0), 1)
            var delta = hue - secondaryHue
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            let shade = BrowserBoostColors.normalizedHue(secondaryHue + delta * t)
            return BrowserBoostColors.rgb(
                hue: shade,
                saturation: saturation,
                lightness: Self.darkest + (Self.lightest - Self.darkest) * t,
            )
        }

        static let darkest = 0.06
        static let lightest = 0.97
    }

    static let contrastRange: ClosedRange<Double> = 0.5 ... 1.5
    static let brightnessRange: ClosedRange<Double> = 0.5 ... 1.5

    var tint: Tint?
    var invertsLightness: Bool
    var contrast: Double
    var brightness: Double
    /// How much of the page's own color stays under the tint, 0 to 1.
    var originalSaturation: Double

    /// Changes nothing on the page.
    var isOriginal: Bool {
        tint == nil && !invertsLightness && contrast == 1 && brightness == 1
    }

    init(
        tint: Tint? = nil,
        invertsLightness: Bool = false,
        contrast: Double = 1,
        brightness: Double = 1,
        originalSaturation: Double = 0,
    ) {
        self.tint = tint
        self.invertsLightness = invertsLightness
        self.contrast = contrast
        self.brightness = brightness
        self.originalSaturation = originalSaturation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tint = try? container.decodeIfPresent(Tint.self, forKey: .tint)
        self.invertsLightness = (try? container.decodeIfPresent(Bool.self, forKey: .invertsLightness)) ?? false
        self.contrast = (try? container.decodeIfPresent(Double.self, forKey: .contrast)) ?? 1
        self.brightness = (try? container.decodeIfPresent(Double.self, forKey: .brightness)) ?? 1
        self.originalSaturation = (try? container.decodeIfPresent(Double.self, forKey: .originalSaturation)) ?? 0
    }

    static func normalizedHue(_ hue: Double) -> Double {
        let value = hue.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// A number as CSS takes it: at most three decimals, no trailing zeros.
    static func number(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        var text = String(format: "%.3f", rounded)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        return text
    }

    static func rgb(hue: Double, saturation: Double, lightness: Double) -> (red: Double, green: Double, blue: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = normalizedHue(hue) / 60
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) =
            switch Int(sector) {
            case 0: (chroma, x, 0)
            case 1: (x, chroma, 0)
            case 2: (0, chroma, x)
            case 3: (0, x, chroma)
            case 4: (x, 0, chroma)
            default: (chroma, 0, x)
            }
        let m = lightness - chroma / 2
        return (r + m, g + m, b + m)
    }

    /// The root's filter, and media turned back so pictures keep their own
    /// lightness. The tint's map is the SVG filter with `filterID`.
    func rules(filterID: String) -> [String] {
        var functions = [String]()
        if invertsLightness {
            functions.append(Self.invertFunctions)
        }
        if tint != nil {
            functions.append("url(#\(filterID))")
        }
        if contrast != 1 {
            functions.append("contrast(\(Self.number(contrast)))")
        }
        if brightness != 1 {
            functions.append("brightness(\(Self.number(brightness)))")
        }
        guard !functions.isEmpty else { return [] }
        var rules = ["html { filter: \(functions.joined(separator: " ")) !important; }"]
        if invertsLightness {
            rules.append("img, video, canvas, iframe, embed, object, svg image { filter: \(Self.invertFunctions) !important; }")
        }
        return rules
    }

    private static let invertFunctions = "invert(1) hue-rotate(180deg)"
}

// MARK: - BrowserBoostTintFilter

/// The SVG filter of a tint: the page's lightness mapped onto the tint's
/// colors, one table per channel, mixed with its own colors by `original`.
struct BrowserBoostTintFilter: Encodable, Equatable {
    static let stopCount = 7

    var red: [Double]
    var green: [Double]
    var blue: [Double]
    var original: Double

    init(tint: BrowserBoostColors.Tint, originalSaturation: Double) {
        var red = [Double](), green = [Double](), blue = [Double]()
        for index in 0 ..< Self.stopCount {
            let color = tint.rgb(atLightness: Double(index) / Double(Self.stopCount - 1))
            red.append(Self.rounded(color.red))
            green.append(Self.rounded(color.green))
            blue.append(Self.rounded(color.blue))
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.original = Self.rounded(min(max(originalSaturation, 0), 1))
    }

    private static func rounded(_ value: Double) -> Double {
        (min(max(value, 0), 1) * 10000).rounded() / 10000
    }
}

// MARK: - BrowserBoostTextCase

enum BrowserBoostTextCase: String, Codable, CaseIterable {
    case capitalize
    case uppercase
    case lowercase
}

// MARK: - BrowserBoostTextZoom

enum BrowserBoostTextZoom {
    static let minimum = 0.9
    static let maximum = 1.5
    /// The sizes the editor offers, 1 being the site's own.
    static let levels: [Double] = [0.9, 1, 1.1, 1.25, 1.5]
}

// MARK: - BrowserBoostFont

/// The fonts the editor's grid offers, five to a row: sans, rounded and
/// monospaced, serif, then display faces.
enum BrowserBoostFont {
    struct Option: Equatable {
        let family: String
        let generic: String
    }

    static let options: [Option] = [
        Option(family: "Helvetica Neue", generic: "sans-serif"),
        Option(family: "Avenir Next", generic: "sans-serif"),
        Option(family: "Futura", generic: "sans-serif"),
        Option(family: "Gill Sans", generic: "sans-serif"),
        Option(family: "Optima", generic: "sans-serif"),
        Option(family: "Arial Rounded MT Bold", generic: "sans-serif"),
        Option(family: "Verdana", generic: "sans-serif"),
        Option(family: "Trebuchet MS", generic: "sans-serif"),
        Option(family: "Menlo", generic: "monospace"),
        Option(family: "Courier New", generic: "monospace"),
        Option(family: "Georgia", generic: "serif"),
        Option(family: "Times New Roman", generic: "serif"),
        Option(family: "Baskerville", generic: "serif"),
        Option(family: "Didot", generic: "serif"),
        Option(family: "Palatino", generic: "serif"),
        Option(family: "Snell Roundhand", generic: "cursive"),
        Option(family: "Bradley Hand", generic: "cursive"),
        Option(family: "American Typewriter", generic: "serif"),
        Option(family: "Copperplate", generic: "serif"),
        Option(family: "Marker Felt", generic: "fantasy"),
    ]

    static let columns = 5

    /// The family quoted, then its generic family as the fallback.
    static func cssValue(_ family: String) -> String {
        let escaped = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let generic = options.first { $0.family == family }?.generic ?? "sans-serif"
        return "\"\(escaped)\", \(generic)"
    }
}
