// BrowserMobileFavicons.swift

import ImageIO
import UIKit

/// Site icons for the phone's chrome, kept per host in memory and in Caches.
@MainActor final class BrowserMobileFavicons {
    // MARK: Internal

    static let shared = BrowserMobileFavicons()
    static let didChange = Notification.Name("BrowserMobileFaviconsDidChange")
    nonisolated static let pixelSize: CGFloat = 96

    // MARK: Private

    private var images = [String: UIImage]()
    private var imagesOnDark = [String: UIImage]()
    private var loading = Set<String>()
    /// Hosts whose page-declared icons all failed.
    private var attempted = Set<String>()
    /// Hosts where only the guessed `/favicon.ico` was tried; a loaded page
    /// may still declare a better one.
    private var guessed = Set<String>()
    private let directory: URL?
    private let session: URLSession

    init(
        directory: URL? = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "Favicons", directoryHint: .isDirectory),
        session: URLSession = .shared,
    ) {
        self.directory = directory
        self.session = session
    }

    // MARK: Internal

    /// The host an icon belongs to: `www.` is the same site.
    nonisolated static func host(forPage urlString: String?) -> String? {
        guard let urlString, let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Orders `[href, rel, sizes, type]` rows from the page: square icons near
    /// 64 px first, then touch icons, then the rest; SVG last since UIKit
    /// cannot draw it.
    nonisolated static func rankedIconURLs(_ rows: [[String]], pageURL: URL?) -> [URL] {
        func score(_ row: [String]) -> Double {
            let rel = row.count > 1 ? row[1].lowercased() : ""
            let sizes = row.count > 2 ? row[2].lowercased() : ""
            let type = row.count > 3 ? row[3].lowercased() : ""
            let href = row[0].lowercased()
            if type.contains("svg") || href.hasSuffix(".svg") { return -1 }
            // An icon drawn by the page is already the right size.
            if href.hasPrefix("data:image/png") { return 100 }
            let side = sizes.split(separator: " ")
                .compactMap { size -> Double? in
                    let parts = size.split(separator: "x")
                    return parts.count == 2 ? Double(parts[0]) : nil
                }
                .max()
            var value = rel.contains("apple-touch-icon") ? 50.0 : 60.0
            if let side { value += 40 - min(abs(side - 64), 64) / 64 * 40 }
            return value
        }
        var seen = Set<String>()
        var result = rows.filter { !$0.isEmpty }
            .sorted { score($0) > score($1) }
            .compactMap { row -> URL? in
                guard let url = URL(string: row[0]), ["http", "https", "data"].contains(url.scheme?.lowercased() ?? ""),
                      seen.insert(url.absoluteString).inserted else { return nil }
                return url
            }
        if let pageURL, var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
           ["http", "https"].contains(components.scheme?.lowercased() ?? "")
        {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            if let fallback = components.url, seen.insert(fallback.absoluteString).inserted {
                result.append(fallback)
            }
        }
        return result
    }

    /// Whether the opaque part of an icon is dark throughout, like a black
    /// logo on a transparent background.
    nonisolated static func isTooDarkForDarkBackground(_ image: CGImage) -> Bool {
        guard let pixels = samplePixels(image) else { return false }
        var opaque = 0, light = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 128 {
            opaque += 1
            let alpha = Double(pixels[index + 3])
            let value = (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])) / alpha
            if value > 0.35 { light += 1 }
        }
        return opaque > 0 && Double(light) / Double(opaque) < 0.1
    }

    /// Whether nothing of an icon shows, like a canvas a page failed to draw on.
    nonisolated static func isBlank(_ image: CGImage) -> Bool {
        guard let pixels = samplePixels(image) else { return true }
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 24 }
    }

    // MARK: Private

    private nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary,
        )
        else { return nil }
        // An .ico holds several sizes; the thumbnail call picks a large one and scales it.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ] as CFDictionary), !isBlank(image) else { return nil }
        return image
    }

    /// The icon drawn at 16 by 16, premultiplied RGBA.
    private nonisolated static func samplePixels(_ image: CGImage) -> [UInt8]? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : nil
    }

    private static func plated(_ image: UIImage) -> UIImage {
        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.92, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.width * 0.22).fill()
            image.draw(in: CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.14, dy: size.height * 0.14))
        }
    }

    func icon(forPage urlString: String?) -> UIImage? {
        guard let host = Self.host(forPage: urlString) else { return nil }
        if let image = images[host] { return image }
        guard let image = readFromDisk(host: host) else { return nil }
        store(image, host: host, persist: false)
        return image
    }

    /// The icon as it reads on the dark switcher and sheets: a mark too dark
    /// to see there sits on a light rounded plate.
    func iconOnDark(forPage urlString: String?) -> UIImage? {
        guard let host = Self.host(forPage: urlString), let image = icon(forPage: urlString) else { return nil }
        if let plated = imagesOnDark[host] { return plated }
        let result = image.cgImage.map(Self.isTooDarkForDarkBackground) == true ? Self.plated(image) : image
        imagesOnDark[host] = result
        return result
    }

    /// Whether an icon is worth asking for: `fromPage` means the page is
    /// loaded and can list its own icons.
    func needsIcon(forPage urlString: String?, fromPage: Bool) -> Bool {
        guard let host = Self.host(forPage: urlString) else { return false }
        return icon(forPage: urlString) == nil && !loading.contains(host) && !attempted.contains(host)
            && (fromPage || !guessed.contains(host))
    }

    /// Tries `candidates` in order and keeps the first image that decodes.
    /// `fromPage` says the page listed them, rather than a guess.
    func load(forPage urlString: String, candidates: [URL], fromPage: Bool) {
        guard let host = Self.host(forPage: urlString), !candidates.isEmpty,
              images[host] == nil, loading.insert(host).inserted else { return }
        let session = session
        Task { [weak self] in
            var found: CGImage?
            for url in candidates {
                guard let (data, response) = try? await session.data(from: url),
                      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                      let image = Self.decode(data) else { continue }
                found = image
                break
            }
            guard let self else { return }
            loading.remove(host)
            if fromPage { attempted.insert(host) } else { guessed.insert(host) }
            guard let found else { return }
            store(UIImage(cgImage: found, scale: 3, orientation: .up), host: host, persist: true)
        }
    }

    private func store(_ image: UIImage, host: String, persist: Bool) {
        images[host] = image
        imagesOnDark[host] = nil
        if persist, let directory, let data = image.pngData() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(host: host, directory: directory), options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["host": host])
    }

    private func readFromDisk(host: String) -> UIImage? {
        guard let directory, let data = try? Data(contentsOf: fileURL(host: host, directory: directory)),
              let image = Self.decode(data) else { return nil }
        return UIImage(cgImage: image, scale: 3, orientation: .up)
    }

    private func fileURL(host: String, directory: URL) -> URL {
        let name = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: ".-")))
            ?? host
        return directory.appending(path: name + ".png")
    }
}
