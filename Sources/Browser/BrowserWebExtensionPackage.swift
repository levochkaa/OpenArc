// BrowserWebExtensionPackage.swift

import CryptoKit
import Foundation
import Security

// MARK: - BrowserWebExtensionPackageError

enum BrowserWebExtensionPackageError: Error, Equatable, LocalizedError {
    case notCRX
    case unsupportedCRXVersion(UInt32)
    case malformedHeader
    case missingSignedData
    case idMismatch(expected: String, found: String)
    case missingPublisherProof
    case missingStoreProof
    case badSignature
    case notZIP
    case unsupportedHash(String)
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .notCRX: "The download is not a Chrome extension package."
        case .unsupportedCRXVersion(let version): "The extension package uses format \(version), which is not supported."
        case .malformedHeader,
             .missingSignedData: "The extension package is damaged."
        case .idMismatch: "The extension package belongs to another extension."
        case .missingPublisherProof: "The extension package is not signed by its publisher."
        case .missingStoreProof: "The extension package is not signed by the Chrome Web Store."
        case .badSignature: "The extension package's signature is not valid."
        case .notZIP: "The extension package holds no archive."
        case .unsupportedHash(let algorithm): "The add-on's checksum uses \(algorithm), which is not supported."
        case .hashMismatch: "The add-on's download does not match its checksum."
        }
    }
}

// MARK: - BrowserCRXPackage

/// A CRX3 file: a protobuf header with signatures, then a ZIP archive.
///
/// Signatures cover `"CRX3 SignedData\0"`, the length of the signed header
/// data as a little-endian `UInt32`, the signed header data and the archive.
/// The signed header data holds the extension's ID: the first 16 bytes of
/// the SHA-256 of the publisher's public key.
struct BrowserCRXPackage {
    /// SHA-256 of the Chrome Web Store's ECDSA P-256 key, which signs every
    /// package the store serves.
    static let webStoreKeyHash = Data([
        0x61, 0xF7, 0xF2, 0xA6, 0xBF, 0xCF, 0x74, 0xCD, 0x0B, 0xC1, 0xFE, 0x24, 0x97, 0xCC, 0x9B, 0x04,
        0x25, 0x4C, 0x65, 0x8F, 0x79, 0xF2, 0x14, 0x53, 0x92, 0x86, 0x7E, 0xA8, 0x36, 0x63, 0x67, 0xCF,
    ])

    private static let magic = Data("Cr24".utf8)
    private static let signaturePrefix = Data("CRX3 SignedData\0".utf8)

    let extensionID: String
    let archive: Data

    /// Parses and verifies a package. The publisher's proof, whose key hashes
    /// to the ID in the signed data, must verify; so must the store's proof
    /// when `storeKeyHash` is set.
    static func verify(
        _ data: Data, expectedID: String?, storeKeyHash: Data? = webStoreKeyHash,
    ) throws -> BrowserCRXPackage {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Data(bytes[0..<4]) == magic else { throw BrowserWebExtensionPackageError.notCRX }
        let version = littleEndianUInt32(bytes, at: 4)
        guard version == 3 else { throw BrowserWebExtensionPackageError.unsupportedCRXVersion(version) }
        let headerSize = Int(littleEndianUInt32(bytes, at: 8))
        guard headerSize <= bytes.count - 12 else { throw BrowserWebExtensionPackageError.malformedHeader }
        let header = Array(bytes[12..<(12 + headerSize)])
        let archive = Data(bytes[(12 + headerSize)...])
        guard archive.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw BrowserWebExtensionPackageError.notZIP }

        var rsaProofs = [(key: Data, signature: Data)]()
        var ecdsaProofs = [(key: Data, signature: Data)]()
        var signedHeaderData: Data?
        for field in try BrowserProtobufReader.fields(header) {
            switch (field.number, field.value) {
            case (2, .bytes(let proof)),
                 (3, .bytes(let proof)):
                var key: Data?
                var signature: Data?
                for part in try BrowserProtobufReader.fields([UInt8](proof)) {
                    if case .bytes(let value) = part.value {
                        if part.number == 1 { key = value }
                        if part.number == 2 { signature = value }
                    }
                }
                guard let key, let signature else { throw BrowserWebExtensionPackageError.malformedHeader }
                if field.number == 2 {
                    rsaProofs.append((key, signature))
                } else {
                    ecdsaProofs.append((key, signature))
                }
            case (10000, .bytes(let value)):
                signedHeaderData = value
            default:
                continue
            }
        }
        guard let signedHeaderData else { throw BrowserWebExtensionPackageError.missingSignedData }
        var crxID: Data?
        for field in try BrowserProtobufReader.fields([UInt8](signedHeaderData)) {
            if field.number == 1, case .bytes(let value) = field.value { crxID = value }
        }
        guard let crxID, crxID.count == 16 else { throw BrowserWebExtensionPackageError.missingSignedData }
        let extensionID = encodeID(crxID)
        if let expectedID, expectedID != extensionID {
            throw BrowserWebExtensionPackageError.idMismatch(expected: expectedID, found: extensionID)
        }

        var message = signaturePrefix
        var length = UInt32(signedHeaderData.count).littleEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(signedHeaderData)
        message.append(archive)

        let publisher = (rsaProofs + ecdsaProofs).filter { Data(SHA256.hash(data: $0.key).prefix(16)) == crxID }
        guard !publisher.isEmpty else { throw BrowserWebExtensionPackageError.missingPublisherProof }
        for proof in publisher {
            let isRSA = rsaProofs.contains { $0.key == proof.key }
            let valid = isRSA
                ? verifyRSA(key: proof.key, signature: proof.signature, message: message)
                : verifyECDSA(key: proof.key, signature: proof.signature, message: message)
            guard valid else { throw BrowserWebExtensionPackageError.badSignature }
        }
        if let storeKeyHash {
            let store = (rsaProofs + ecdsaProofs).filter { Data(SHA256.hash(data: $0.key)) == storeKeyHash }
            guard !store.isEmpty else { throw BrowserWebExtensionPackageError.missingStoreProof }
            for proof in store {
                let isRSA = rsaProofs.contains { $0.key == proof.key }
                let valid = isRSA
                    ? verifyRSA(key: proof.key, signature: proof.signature, message: message)
                    : verifyECDSA(key: proof.key, signature: proof.signature, message: message)
                guard valid else { throw BrowserWebExtensionPackageError.badSignature }
            }
        }
        return BrowserCRXPackage(extensionID: extensionID, archive: archive)
    }

    /// The extension ID of a public key: the first 16 bytes of its SHA-256,
    /// each half byte written as a letter from `a` to `p`.
    static func extensionID(forPublicKey key: Data) -> String {
        encodeID(Data(SHA256.hash(data: key).prefix(16)))
    }

    private static func encodeID(_ bytes: Data) -> String {
        var id = ""
        for byte in bytes {
            id.append(Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))))
            id.append(Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 0x0F))))
        }
        return id
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func verifyRSA(key: Data, signature: Data, message: Data) -> Bool {
        guard let pkcs1 = BrowserDERReader.subjectPublicKey(key) else { return false }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(
            secKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil,
        )
    }

    private static func verifyECDSA(key: Data, signature: Data, message: Data) -> Bool {
        guard let publicKey = try? P256.Signing.PublicKey(derRepresentation: key),
              let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return publicKey.isValidSignature(ecdsa, for: message)
    }
}

// MARK: - BrowserXPIChecksum

/// AMO lists each file's checksum as `sha256:<hex>`.
enum BrowserXPIChecksum {
    static func verify(_ data: Data, hash: String) throws {
        let parts = hash.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw BrowserWebExtensionPackageError.unsupportedHash(hash) }
        guard parts[0].lowercased() == "sha256" else { throw BrowserWebExtensionPackageError.unsupportedHash(parts[0]) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == parts[1].lowercased() else { throw BrowserWebExtensionPackageError.hashMismatch }
    }
}

// MARK: - BrowserProtobufReader

/// Reads the fields of one protobuf message: varints and length-delimited values.
enum BrowserProtobufReader {
    enum Value: Equatable {
        case varint(UInt64)
        case bytes(Data)
    }

    struct Field: Equatable {
        let number: Int
        let value: Value
    }

    static func fields(_ bytes: [UInt8]) throws -> [Field] {
        var index = 0
        var fields = [Field]()
        while index < bytes.count {
            let key = try varint(bytes, &index)
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                try fields.append(Field(number: number, value: .varint(varint(bytes, &index))))
            case 2:
                let length = try varint(bytes, &index)
                guard length <= UInt64(bytes.count - index)
                else { throw BrowserWebExtensionPackageError.malformedHeader }
                let end = index + Int(length)
                fields.append(Field(number: number, value: .bytes(Data(bytes[index..<end]))))
                index = end
            case 1:
                guard index + 8 <= bytes.count else { throw BrowserWebExtensionPackageError.malformedHeader }
                index += 8
            case 5:
                guard index + 4 <= bytes.count else { throw BrowserWebExtensionPackageError.malformedHeader }
                index += 4
            default:
                throw BrowserWebExtensionPackageError.malformedHeader
            }
        }
        return fields
    }

    private static func varint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        throw BrowserWebExtensionPackageError.malformedHeader
    }
}

// MARK: - BrowserDERReader

/// Just enough DER to take the key out of a SubjectPublicKeyInfo.
enum BrowserDERReader {
    /// The BIT STRING of `SEQUENCE { SEQUENCE { algorithm }, BIT STRING }`,
    /// without its unused-bits byte.
    static func subjectPublicKey(_ spki: Data) -> Data? {
        let bytes = [UInt8](spki)
        var index = 0
        guard let outer = element(bytes, &index), outer.tag == 0x30 else { return nil }
        var inner = outer.start
        guard let algorithm = element(bytes, &inner), algorithm.tag == 0x30 else { return nil }
        inner = algorithm.end
        guard let bitString = element(bytes, &inner), bitString.tag == 0x03,
              bitString.end > bitString.start, bytes[bitString.start] == 0 else { return nil }
        return Data(bytes[(bitString.start + 1)..<bitString.end])
    }

    private static func element(_ bytes: [UInt8], _ index: inout Int) -> (tag: UInt8, start: Int, end: Int)? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        var length = Int(bytes[index + 1])
        index += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard length <= bytes.count - index else { return nil }
        let start = index
        index += length
        return (tag, start, index)
    }
}
