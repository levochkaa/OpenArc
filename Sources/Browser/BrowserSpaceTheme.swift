// BrowserSpaceTheme.swift

import AppKit
import simd

// MARK: - BrowserSpaceTheme

/// A Space's look: up to three colors, how strongly they cover the window and a
/// paper texture. Local to this device, stored as JSON beside the Space.
struct BrowserSpaceTheme: Codable, Equatable {
    /// Extended sRGB, so saturated Display P3 colors survive.
    struct Color: Codable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        /// Display P3 HSL: hue in degrees, saturation and lightness in 0...1.
        var hsl: (hue: Double, saturation: Double, lightness: Double) {
            let (r, g, b) = displayP3
            let high = max(r, g, b)
            let low = min(r, g, b)
            let chroma = high - low
            let lightness = (high + low) / 2
            guard chroma > 0.00001 else { return (0, 0, lightness) }
            let hue: Double =
                if high == r {
                    ((g - b) / chroma + (g < b ? 6 : 0)) * 60
                } else if high == g {
                    ((b - r) / chroma + 2) * 60
                } else {
                    ((r - g) / chroma + 4) * 60
                }
            return (hue, chroma / max(1 - abs(2 * lightness - 1), 0.00001), lightness)
        }

        var nsColor: NSColor { nsColor(alpha: 1) }

        /// Relative luminance, which decides between dark and light content.
        var luminance: Double {
            0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
        }

        var oklab: SIMD3<Float> {
            let r = Self.linear(red)
            let g = Self.linear(green)
            let b = Self.linear(blue)
            let l = Self.cubeRoot(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = Self.cubeRoot(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = Self.cubeRoot(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return SIMD3(
                Float(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s),
                Float(1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s),
                Float(0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s),
            )
        }

        private var displayP3: (Double, Double, Double) {
            let r = Self.linear(red)
            let g = Self.linear(green)
            let b = Self.linear(blue)
            return (
                Self.encoded(0.8224621 * r + 0.1775380 * g),
                Self.encoded(0.0331941 * r + 0.9668058 * g),
                Self.encoded(0.0170827 * r + 0.0723974 * g + 0.9105199 * b),
            )
        }

        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// Hue in degrees, with saturation and lightness of Display P3 HSL.
        init(hue: Double, saturation: Double, lightness: Double) {
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
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
            self = Self.fromDisplayP3(r + m, g + m, b + m)
        }

        static func linear(_ value: Double) -> Double {
            let magnitude = abs(value)
            let result = magnitude <= 0.04045 ? magnitude / 12.92 : pow((magnitude + 0.055) / 1.055, 2.4)
            return value < 0 ? -result : result
        }

        static func encoded(_ value: Double) -> Double {
            let magnitude = abs(value)
            let result = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
            return value < 0 ? -result : result
        }

        private static func fromDisplayP3(_ red: Double, _ green: Double, _ blue: Double) -> Color {
            let r = linear(red)
            let g = linear(green)
            let b = linear(blue)
            return Color(
                encoded(1.2249401 * r - 0.2249404 * g),
                encoded(-0.0420569 * r + 1.0420571 * g),
                encoded(-0.0196376 * r - 0.0786361 * g + 1.0982735 * b),
            )
        }

        private static func cubeRoot(_ value: Double) -> Double {
            value < 0 ? -pow(-value, 1.0 / 3) : pow(value, 1.0 / 3)
        }

        func nsColor(alpha: Double) -> NSColor {
            let components = [red, green, blue, alpha].map { CGFloat($0) }
            return NSColor(colorSpace: .extendedSRGB, components: components, count: 4)
        }

        func cssValue(alpha: Double = 1) -> String {
            let channel = { (value: Double) in Int((min(max(value, 0), 1) * 255).rounded()) }
            return "rgba(\(channel(red)), \(channel(green)), \(channel(blue)), \(alpha))"
        }

        func mixedWithWhite(_ amount: Double) -> Color {
            Color(red + (1 - red) * amount, green + (1 - green) * amount, blue + (1 - blue) * amount)
        }

        func scaled(_ amount: Double) -> Color { Color(red * amount, green * amount, blue * amount) }

        func withLightness(_ lightness: Double) -> Color {
            let (hue, saturation, _) = hsl
            return Color(hue: hue, saturation: saturation, lightness: lightness)
        }
    }

    /// The paper laid over the colors; each is drawn at its own strength.
    enum Texture: String, Codable, CaseIterable {
        case grain
        case sand
        case denim
        case tweed

        // MARK: Internal

        var strength: Double {
            switch self {
            case .grain: 0.8
            case .sand: 0.15
            case .denim: 0.6
            case .tweed: 0.4
            }
        }

        var next: Texture {
            let all = Self.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    /// Which backing lies under the colors: black, white or the system's choice.
    enum Mode: String, Codable, CaseIterable {
        case automatic
        case light
        case dark
    }

    /// How the second and third colors follow the key color around the wheel.
    enum Wheel: String, Codable {
        case complementary
        case analogous
    }

    /// Colors of the theme's text and fills on its background.
    struct Palette: Equatable {
        let key: Color
        let isLightContent: Bool

        /// The fill of whatever carries the theme's color behind white content.
        var accentFill: NSColor {
            let color = key.nsColor
            return color.blended(withFraction: 0.45, of: .black) ?? color
        }

        /// The theme as CSS variables, for pages that adapt to the Space's colors.
        var cssVariables: [(name: String, value: String)] {
            let dark = !isLightContent
            let colors: [(String, Color, Double)] = [
                ("title", title, 1),
                ("subtitle", dark ? shadedDark.mixedWithWhite(0.47) : shadedDark.mixedWithWhite(0.6), 1),
                ("background", dark ? shadedDark.scaled(0.3) : shadedDark.mixedWithWhite(0.9), 1),
                ("backgroundExtra", dark ? shadedDark.scaled(0.15) : shadedDark.mixedWithWhite(0.99), 1),
                ("cutoutColor", dark ? shadedDark : tintedLight, 1),
                ("focus", dark ? shadedDark.mixedWithWhite(0.195) : shadedDark.mixedWithWhite(0.5), dark ? 0.8075 : 1),
                ("hover", dark ? shadedDark.mixedWithWhite(0.27) : shadedDark.mixedWithWhite(0.8), dark ? 0.48 : 1),
                ("foregroundPrimary", dark ? tintedLight : key, 1),
                ("foregroundSecondary", key, 1),
                ("foregroundTertiary", dark ? key : tintedLight, 1),
                ("maxContrastColor", dark ? tintedLight : shadedDark, 1),
                ("minContrastColor", dark ? shadedDark : tintedLight, 1),
            ]
            return colors.map { ("--arc-palette-\($0.0)", $0.1.cssValue(alpha: $0.2)) }
        }

        var tintedLight: Color { key.withLightness(0.94) }
        var shadedDark: Color { key.withLightness(key.hsl.lightness / 2) }
        var title: Color { isLightContent ? shadedDark.scaled(0.3) : shadedDark.mixedWithWhite(0.85) }
        var selection: NSColor { tintedLight.nsColor(alpha: isLightContent ? 0.5 : 0.2) }
        /// Behind a folder that takes a dragged tab: the most contrasting color, half covered.
        var dropTargetBand: NSColor {
            isLightContent ? shadedDark.nsColor(alpha: 0.5) : tintedLight.nsColor(alpha: 0.45)
        }

        /// The editor's card.
        var card: Color { shadedDark.scaled(0.3).mixedWithWhite(0.15) }
    }

    static let maximumColors = 3
    static let padSize: CGFloat = 340
    /// How much lightness one point of distance from the pad's center adds.
    static let lightnessPerPoint = 0.00296
    /// Where a preset's key color sits on the pad, away from the center.
    static let presetKnobRadius = 84.0

    private static let legacyColors: [String: Color] = [
        "blue": Color(0.424, 0.729, 0.851),
        "purple": Color(0.651, 0.447, 0.616),
        "pink": Color(0.95, 0.608, 0.733),
        "red": Color(0.949, 0.369, 0.42),
        "orange": Color(1, 0.522, 0.344),
        "yellow": Color(0.973, 0.835, 0.346),
        "green": Color(0.204, 0.91, 0.584),
        "teal": Color(0.133, 0.381, 0.288),
        "gray": Color(0.5, 0.5, 0.5),
    ]

    var colors: [Color]
    var wheel: Wheel
    /// Lightness at the pad's center; it moves with the chosen preset.
    var lightnessAtCenter: Double
    var saturation: Double
    var intensity: Double
    var noise: Double
    var texture: Texture
    var mode: Mode

    var key: Color? { colors.first }
    var palette: Palette? { key.map { Palette(key: $0, isLightContent: $0.luminance > 0.179) } }
    var coverage: Float { 0.2 + 0.55 * Float(intensity) }
    var canAddColor: Bool { !colors.isEmpty && colors.count < Self.maximumColors }

    var stored: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Where each color's knob sits, in the pad's top-left coordinates.
    var knobPositions: [CGPoint] {
        colors.map { color in
            let (hue, _, lightness) = color.hsl
            let radius = max(lightness - lightnessAtCenter, 0) / Self.lightnessPerPoint
            let angle = hue * .pi / 180
            let center = Self.padSize / 2
            return CGPoint(x: center + radius * cos(angle), y: center + radius * sin(angle))
        }
    }

    /// Sets the theme's variables on each new page; nil without a theme.
    var pageScript: String? {
        guard let palette, let key else { return nil }
        var variables = palette.cssVariables
        variables.append(("--arc-background-simple-color", key.cssValue()))
        if colors.count > 1 {
            variables.append(("--arc-background-gradient-color0", colors[0].cssValue()))
            variables.append(("--arc-background-gradient-color1", colors[1].cssValue()))
        }
        if colors.count > 2 {
            variables.append(("--arc-background-gradient-overlay-color0", "rgba(0, 0, 0, 0)"))
            variables.append(("--arc-background-gradient-overlay-color1", colors[2].cssValue()))
        }
        let calls = variables.map { "s.setProperty('\($0.name)','\($0.value)');" }.joined()
        return "(function(){function a(){var s=document.documentElement.style;\(calls)}"
            + "if(document.documentElement){a();}else{document.addEventListener('readystatechange',a,{once:true});}})();"
    }

    init(
        colors: [Color] = [],
        wheel: Wheel = .complementary,
        lightnessAtCenter: Double = 0.4,
        saturation: Double = 0.8,
        intensity: Double = 1,
        noise: Double = 0,
        texture: Texture = .grain,
        mode: Mode = .automatic,
    ) {
        self.colors = colors
        self.wheel = wheel
        self.lightnessAtCenter = lightnessAtCenter
        self.saturation = saturation
        self.intensity = intensity
        self.noise = noise
        self.texture = texture
        self.mode = mode
    }

    /// A chosen preset: its key color at its usual place on the pad.
    init(key: Color, colorCount: Int = 1, wheel: Wheel = .complementary) {
        let (_, saturation, lightness) = key.hsl
        self.init(
            colors: [key],
            wheel: wheel,
            lightnessAtCenter: min(lightness - Self.presetKnobRadius * Self.lightnessPerPoint, 0.5),
            saturation: saturation,
        )
        self.colors = Self.colors(key: key, count: colorCount, wheel: wheel)
    }

    /// The value in storage: this theme's JSON, or a color name from older versions.
    init?(stored: String) {
        if let data = stored.data(using: .utf8), let decoded = try? JSONDecoder().decode(Self.self, from: data) {
            self = decoded
        } else if let legacy = Self.legacyColors[stored] {
            self.init(key: legacy)
        } else {
            return nil
        }
    }

    /// Other colors for a key color: the far side of the wheel, or its neighbors.
    static func colors(key: Color, count: Int, wheel: Wheel) -> [Color] {
        let offsets: [Double] =
            switch (wheel, count) {
            case (.complementary, 2): [180]
            case (.complementary, 3...): [150, 210]
            case (.analogous, 2): [40]
            case (.analogous, 3...): [40, -40]
            default: []
            }
        let (hue, saturation, lightness) = key.hsl
        return [key] + offsets.map { Color(hue: hue + $0, saturation: saturation, lightness: lightness) }
    }

    /// Moves all knobs together so the key color sits at this point of the pad.
    mutating func moveKey(to point: CGPoint) {
        let center = Self.padSize / 2
        let dx = Double(point.x - center)
        let dy = Double(point.y - center)
        let hue = atan2(dy, dx) * 180 / .pi
        let lightness = min(max(lightnessAtCenter + hypot(dx, dy) * Self.lightnessPerPoint, 0), 1)
        let key = Color(hue: hue, saturation: saturation, lightness: lightness)
        colors = Self.colors(key: key, count: max(colors.count, 1), wheel: wheel)
    }

    mutating func addColor() {
        guard let key, canAddColor else { return }
        colors = Self.colors(key: key, count: colors.count + 1, wheel: wheel)
    }

    /// The last color goes too, which leaves the Space without a theme color.
    mutating func removeColor() {
        guard let key else { return }
        colors = colors.count == 1 ? [] : Self.colors(key: key, count: colors.count - 1, wheel: wheel)
    }
}

// MARK: - BrowserSpaceThemePresets

/// The editor's swatches, five pages of nine.
enum BrowserSpaceThemePresets {
    struct Swatch: Equatable {
        let key: BrowserSpaceTheme.Color
        let colorCount: Int
        let wheel: BrowserSpaceTheme.Wheel

        var theme: BrowserSpaceTheme { BrowserSpaceTheme(key: key, colorCount: colorCount, wheel: wheel) }
        var colors: [BrowserSpaceTheme.Color] { BrowserSpaceTheme.colors(key: key, count: colorCount, wheel: wheel) }
    }

    static let pages: [[Swatch]] = [
        single.map { Swatch(key: $0, colorCount: 1, wheel: .complementary) },
        single.map { Swatch(key: $0, colorCount: 3, wheel: .analogous) },
        pastel.map { Swatch(key: $0, colorCount: 1, wheel: .complementary) },
        drab.map { Swatch(key: $0, colorCount: 1, wheel: .complementary) },
        grey.map { Swatch(key: $0, colorCount: 1, wheel: .complementary) },
    ]

    private static let single = [
        rgb(0.95, 0.918, 0.894), rgb(0.95, 0.608, 0.733), rgb(0.651, 0.447, 0.616),
        rgb(0.949, 0.369, 0.42), rgb(1, 0.522, 0.344), rgb(0.973, 0.835, 0.346),
        rgb(0.204, 0.91, 0.584), rgb(0.424, 0.729, 0.851), rgb(0.4, 0.404, 0.537),
    ]
    private static let pastel = [
        rgb(0.996, 0.984, 0.981), rgb(0.999, 0.914, 0.953), rgb(0.944, 0.82, 0.925),
        rgb(1, 0.796, 0.82), rgb(1, 0.878, 0.827), rgb(1, 0.976, 0.898),
        rgb(0.871, 0.992, 0.922), rgb(0.863, 0.953, 0.988), rgb(0.774, 0.776, 0.898),
    ]
    private static let drab = [
        rgb(0.306, 0.228, 0.353), rgb(0.411, 0.21, 0.343), rgb(0.561, 0.249, 0.259),
        rgb(0.692, 0.427, 0.25), rgb(0.843, 0.701, 0.366), rgb(0.805, 0.8, 0.643),
        rgb(0.479, 0.664, 0.509), rgb(0.133, 0.381, 0.288), rgb(0.147, 0.27, 0.42),
    ]
    private static let grey = [1, 0.9, 0.8, 0.7, 0.5, 0.4, 0.2, 0.1, 0].map { rgb($0, $0, $0) }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> BrowserSpaceTheme.Color {
        BrowserSpaceTheme.Color(red, green, blue)
    }
}

// MARK: - BrowserSpaceThemeRenderer

/// Draws a theme into a small floating point image that its layer stretches: two
/// linear gradients blended in Oklab, so hues stay clean between the colors.
enum BrowserSpaceThemeRenderer {
    /// Premultiplied pixels of the theme for a window of this shape.
    static func pixels(
        for theme: BrowserSpaceTheme,
        aspect: CGFloat,
        isDark: Bool,
        width: Int = 128,
    ) -> (values: [Float], width: Int, height: Int)? {
        guard let first = theme.colors.first?.oklab else { return nil }
        let height = max(Int((CGFloat(width) / max(aspect, 0.1)).rounded()), 8)
        var values = [Float](repeating: 0, count: width * height * 4)
        let second = theme.colors.count > 1 ? theme.colors[1].oklab : first
        let overlay = theme.colors.count > 2 ? theme.colors[2].oklab : nil
        let coverage = theme.coverage
        let backingColor: Float = isDark ? 0 : 1
        let backingAlpha: Float = isDark ? min(0.175, coverage * 0.35) : 0.5
        // The base axis runs corner to corner in a square of the window's width.
        let shape = Float(1 / max(aspect, 0.1))
        let originY = 0.5 - 0.5 * shape
        let axisLengthSquared = 1 + shape * shape
        for row in 0..<height {
            let v = (Float(row) + 0.5) / Float(height)
            for column in 0..<width {
                let u = (Float(column) + 0.5) / Float(width)
                let along = (u + (v - originY) * shape) / axisLengthSquared
                let t = min(max(along, 0), 1) * 1.3333333
                var oklab = first + (second - first) * min(t, 1)
                var alpha = coverage
                if let overlay {
                    let overlayAlpha = v * coverage
                    let combined = overlayAlpha + (1 - overlayAlpha) * alpha
                    let baseShare = alpha * (1 - overlayAlpha)
                    oklab = (overlay * overlayAlpha + oklab * baseShare) / combined
                    alpha = combined
                }
                let rgb = encodedSRGB(oklab)
                let outAlpha = alpha + backingAlpha * (1 - alpha)
                let backing = backingColor * backingAlpha * (1 - alpha)
                let index = (row * width + column) * 4
                values[index] = rgb.x * alpha + backing
                values[index + 1] = rgb.y * alpha + backing
                values[index + 2] = rgb.z * alpha + backing
                values[index + 3] = outAlpha
            }
        }
        return (values, width, height)
    }

    static func image(for theme: BrowserSpaceTheme, aspect: CGFloat, isDark: Bool) -> CGImage? {
        guard let (values, width, height) = pixels(for: theme, aspect: aspect, isDark: isDark),
              let space = CGColorSpace(name: CGColorSpace.extendedSRGB)
        else { return nil }
        let data = values.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 32,
            bitsPerPixel: 128,
            bytesPerRow: width * 16,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent,
        )
    }

    private static func encodedSRGB(_ oklab: SIMD3<Float>) -> SIMD3<Float> {
        let l = oklab.x + 0.3963377774 * oklab.y + 0.2158037573 * oklab.z
        let m = oklab.x - 0.1055613458 * oklab.y - 0.0638541728 * oklab.z
        let s = oklab.x - 0.0894841775 * oklab.y - 1.2914855480 * oklab.z
        let l3 = l * l * l
        let m3 = m * m * m
        let s3 = s * s * s
        return SIMD3(
            encode(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            encode(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            encode(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
        )
    }

    private static func encode(_ value: Float) -> Float {
        let magnitude = abs(value)
        let result = magnitude <= 0.0031308 ? magnitude * 12.92 : 1.055 * pow(magnitude, 1 / 2.4) - 0.055
        return value < 0 ? -result : result
    }
}

// MARK: - BrowserSpaceThemeTexture

/// Tiles of each texture, 100 pt wide and drawn in code. Each darkens what lies
/// below it, so a tile is black with varying alpha, plus a little color for grain.
@MainActor enum BrowserSpaceThemeTexture {
    nonisolated static let tileSize = 100

    private static var tiles = [BrowserSpaceTheme.Texture: NSImage]()

    static func tile(_ texture: BrowserSpaceTheme.Texture) -> NSImage {
        if let cached = tiles[texture] { return cached }
        let image = makeTile(texture)
        tiles[texture] = image
        return image
    }

    /// How much each pixel darkens the theme, row by row, for a tile twice `tileSize` wide.
    nonisolated static func darkness(_ texture: BrowserSpaceTheme.Texture) -> [Float] {
        let size = tileSize * 2
        var random = SplitMix(state: 0x4F_7065_6E41_7263 &+ UInt64(texture.rawValue.count))
        switch texture {
        case .grain:
            return (0..<size * size).map { _ in random.unit() * 0.26 }
        case .sand:
            return sand(size: size, random: &random)
        case .denim:
            return (0..<size * size).map { index in
                let x = Float(index % size)
                let y = Float(index / size)
                // Fine diagonal lines that repeat exactly across the tile's edge.
                let phase = (x + y) / Float(size) * 2 * .pi * 25
                return 0.16 + 0.1 * sin(phase) + random.unit() * 0.03
            }
        case .tweed:
            return tweed(size: size, random: &random)
        }
    }

    private static func makeTile(_ texture: BrowserSpaceTheme.Texture) -> NSImage {
        let size = tileSize * 2
        let values = darkness(texture)
        var random = SplitMix(state: 0x67_7261_696E)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<size * size {
            let alpha = min(max(values[index], 0), 1)
            let offset = index * 4
            if texture == .grain {
                bytes[offset] = UInt8(random.unit() * alpha * 180)
                bytes[offset + 1] = UInt8(random.unit() * alpha * 180)
                bytes[offset + 2] = UInt8(random.unit() * alpha * 180)
            }
            bytes[offset + 3] = UInt8(alpha * 255)
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: size * 4,
            bitsPerPixel: 32,
        )
        bytes.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress, let target = rep?.bitmapData {
                target.update(from: base.assumingMemoryBound(to: UInt8.self), count: buffer.count)
            }
        }
        let image = NSImage(size: NSSize(width: tileSize, height: tileSize))
        if let rep {
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }

    /// Pebbles: bright stones with dark gaps, by distance to the nearest two points.
    private nonisolated static func sand(size: Int, random: inout SplitMix) -> [Float] {
        let cells = 26
        let cell = Float(size) / Float(cells)
        let points = (0..<cells * cells).map { _ in SIMD2(random.unit(), random.unit()) }
        var values = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let px = Float(x) / cell
                let py = Float(y) / cell
                var nearest = Float.greatestFiniteMagnitude
                var second = Float.greatestFiniteMagnitude
                for dy in -1...1 {
                    for dx in -1...1 {
                        let cx = Int(px) + dx
                        let cy = Int(py) + dy
                        let wrapped = ((cy + cells) % cells) * cells + ((cx + cells) % cells)
                        let point = points[wrapped] + SIMD2(Float(cx), Float(cy))
                        let distance = simd_distance(point, SIMD2(px, py))
                        if distance < nearest {
                            second = nearest
                            nearest = distance
                        } else if distance < second {
                            second = distance
                        }
                    }
                }
                let edge = min(max((second - nearest) * 5, 0), 1)
                values[y * size + x] = 0.95 - 0.8 * edge
            }
        }
        return values
    }

    /// Soft gray cloud with fine fiber, wrapped so the tile repeats without a seam.
    private nonisolated static func tweed(size: Int, random: inout SplitMix) -> [Float] {
        let lattice = 12
        let heights = (0..<lattice * lattice).map { _ in random.unit() }
        func height(
            _ x: Int,
            _ y: Int,
        ) -> Float { heights[((y + lattice) % lattice) * lattice + (x + lattice) % lattice] }
        func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
        var values = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let fx = Float(x) / Float(size) * Float(lattice)
                let fy = Float(y) / Float(size) * Float(lattice)
                let ix = Int(fx)
                let iy = Int(fy)
                let tx = smooth(fx - Float(ix))
                let ty = smooth(fy - Float(iy))
                let top = height(ix, iy) + (height(ix + 1, iy) - height(ix, iy)) * tx
                let bottom = height(ix, iy + 1) + (height(ix + 1, iy + 1) - height(ix, iy + 1)) * tx
                let cloud = top + (bottom - top) * ty
                values[y * size + x] = 0.2 + cloud * 0.14 + random.unit() * 0.08
            }
        }
        return values
    }
}

// MARK: - SplitMix

/// A small seeded generator, so textures look the same on every launch.
private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

// MARK: - BrowserSpaceThemedChrome

/// Chrome that lies on a Space's theme and gives its palette to the rows inside.
@MainActor protocol BrowserSpaceThemedChrome: NSView {
    var spaceThemePalette: BrowserSpaceTheme.Palette? { get }
}

extension NSView {
    var enclosingSpaceThemePalette: BrowserSpaceTheme.Palette? {
        var view: NSView? = self
        while let current = view {
            if let chrome = current as? any BrowserSpaceThemedChrome { return chrome.spaceThemePalette }
            view = current.superview
        }
        return nil
    }
}

// MARK: - BrowserSpaceTheme.Color + spoken name

extension BrowserSpaceTheme.Color {
    /// A plain name for VoiceOver, such as "Light Blue", from the color's hue,
    /// saturation and lightness.
    var spokenName: String {
        let (hue, saturation, lightness) = hsl
        if saturation < 0.12 || lightness > 0.97 || lightness < 0.06 {
            return lightness > 0.9
                ? BrowserStrings.colorWhite
                : lightness < 0.12 ? BrowserStrings.colorBlack : BrowserStrings.colorGray
        }
        let base =
            switch hue {
            case 15..<40: BrowserStrings.colorOrange
            case 40..<65: BrowserStrings.colorYellow
            case 65..<150: BrowserStrings.colorGreen
            case 150..<190: BrowserStrings.colorTeal
            case 190..<255: BrowserStrings.colorBlue
            case 255..<290: BrowserStrings.colorPurple
            case 290..<345: BrowserStrings.colorPink
            default: BrowserStrings.colorRed
            }
        if lightness > 0.8 { return BrowserStrings.colorLight(base) }
        if lightness < 0.3 { return BrowserStrings.colorDark(base) }
        return base
    }
}
