// BrowserWebAppIcon.swift

import AppKit
import Foundation

// MARK: - BrowserWebAppIconLoader

@MainActor enum BrowserWebAppIconLoader {
    static func loadBundleIconData(from url: URL?) async -> Data? {
        guard let url else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode)
            {
                return nil
            }
            return BrowserWebAppBundleIconEncoder.icnsData(fromEncodedImageData: data)
        } catch {
            return nil
        }
    }
}

// MARK: - BrowserWebAppBundleIconEncoder

enum BrowserWebAppBundleIconEncoder {
    // MARK: Internal

    static func icnsData(from image: NSImage) -> Data? {
        guard let pngData = BrowserImageThumbnailer.macOSApplicationIconPNGData(from: image) else {
            return nil
        }
        return icnsData(pngData: pngData)
    }

    static func icnsData(fromEncodedImageData data: Data) -> Data? {
        guard let pngData = BrowserImageThumbnailer.macOSApplicationIconPNGData(fromEncodedImageData: data) else {
            return nil
        }
        return icnsData(pngData: pngData)
    }

    static func icnsData(pngData: Data) -> Data {
        let imageBlock = block(type: "ic09", payload: pngData)
        let tableOfContentsEntry = blockHeader(type: "ic09", payloadLength: pngData.count)
        let tableOfContentsBlock = block(type: "TOC ", payload: tableOfContentsEntry)
        let totalLength = 8 + tableOfContentsBlock.count + imageBlock.count

        var data = Data("icns".utf8)
        data.append(bigEndianUInt32(totalLength))
        data.append(tableOfContentsBlock)
        data.append(imageBlock)
        return data
    }

    // MARK: Private

    private static func block(type: String, payload: Data) -> Data {
        var data = blockHeader(type: type, payloadLength: payload.count)
        data.append(payload)
        return data
    }

    private static func blockHeader(type: String, payloadLength: Int) -> Data {
        var data = Data(type.utf8)
        data.append(bigEndianUInt32(payloadLength + 8))
        return data
    }

    private static func bigEndianUInt32(_ value: Int) -> Data {
        var value = UInt32(value).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
