// BrowserFairPlayInitData.swift

import Foundation

// MARK: - BrowserFairPlayInitData

/// Reads the key IDs from the init data FairPlay players pass to EME.
enum BrowserFairPlayInitData {
    static let fairPlaySystemID = Data([
        0x94, 0xCE, 0x86, 0xFB, 0x07, 0xFF, 0x4F, 0x43, 0xAD, 0xB8, 0x93, 0xD2, 0xFA, 0x96, 0x8C, 0xA2,
    ])

    /// The default key IDs of the `tenc` boxes in a `{"sinf": [base64…]}` init data.
    static func sinfKeyIDs(_ data: Data) -> [Data] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boxes = object["sinf"] as? [String] else { return [] }
        return boxes.compactMap { Data(base64Encoded: $0) }.compactMap(tencKeyID)
    }

    /// `tenc`: version and flags (4), reserved (1), crypt and skip blocks (1),
    /// protected (1), IV size (1), then the 16-byte default key ID.
    static func tencKeyID(_ box: Data) -> Data? {
        let bytes = [UInt8](box)
        let tenc: [UInt8] = Array("tenc".utf8)
        guard bytes.count >= 24 else { return nil }
        for index in 4...(bytes.count - 4) where Array(bytes[index..<index + 4]) == tenc {
            let start = index + 4 + 4 + 4
            guard start + 16 <= bytes.count else { return nil }
            return Data(bytes[start..<start + 16])
        }
        return nil
    }

    /// The FairPlay `pssh` box among `cenc` init data's boxes.
    static func fairPlayPssh(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 32 <= bytes.count {
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 |
                Int(bytes[offset + 3])
            guard size >= 32, offset + size <= bytes.count else { return nil }
            if Array(bytes[offset + 4..<offset + 8]) == Array("pssh".utf8),
               Data(bytes[offset + 12..<offset + 28]) == fairPlaySystemID
            {
                return Data(bytes[offset..<offset + size])
            }
            offset += size
        }
        return nil
    }

    /// The key IDs of a FairPlay `pssh` box: the list of a version 1 box, else
    /// the `fkri` boxes of the `fpsd` data, each a header and a 16-byte key ID.
    static func psshKeyIDs(_ pssh: Data) -> [Data] {
        let bytes = [UInt8](pssh)
        guard bytes.count >= 32 else { return [] }
        if bytes[8] >= 1 {
            let count = Int(bytes[28]) << 24 | Int(bytes[29]) << 16 | Int(bytes[30]) << 8 | Int(bytes[31])
            if count > 0, count < 64, 32 + count * 16 <= bytes.count {
                return (0..<count).map { Data(bytes[32 + $0 * 16..<48 + $0 * 16]) }
            }
        }
        let fkri = Array("fkri".utf8)
        var keyIDs = [Data]()
        var index = 28
        while index + 4 + 4 + 16 <= bytes.count {
            if Array(bytes[index..<index + 4]) == fkri {
                let start = index + 4 + 4
                let keyID = Data(bytes[start..<start + 16])
                if !keyIDs.contains(keyID) {
                    keyIDs.append(keyID)
                }
                index = start + 16
            } else {
                index += 1
            }
        }
        return keyIDs
    }
}
