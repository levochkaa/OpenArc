import Foundation

enum BrowserRuntimeIdentity {
    // MARK: Internal

    static func suffix(arguments: [String]) -> String? {
        for argument in arguments {
            guard argument.hasPrefix(runtimeSuffixArgumentPrefix) else {
                continue
            }

            let rawSuffix = String(argument.dropFirst(runtimeSuffixArgumentPrefix.count))
            return sanitize(rawSuffix)
        }

        return nil
    }

    static func rootCacheDirectoryName(suffix: String?) -> String {
        suffix.map { "CEF-\($0)" } ?? "CEF"
    }

    static func sessionDirectoryName(suffix: String?) -> String {
        suffix.map { "Session-\($0)" } ?? "Session"
    }

    // MARK: Private

    private static let runtimeSuffixArgumentPrefix = "--runtime-suffix="

    private static func sanitize(_ rawSuffix: String) -> String? {
        let allowedCharacters =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let trimmedRawSuffix = rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawSuffix.isEmpty else {
            return nil
        }

        var sanitizedSuffix = ""
        sanitizedSuffix.reserveCapacity(trimmedRawSuffix.count)
        var lastCharacterWasSeparator = false

        for scalar in trimmedRawSuffix.unicodeScalars {
            if allowedCharacters.contains(scalar) {
                sanitizedSuffix.append(Character(scalar))
                lastCharacterWasSeparator = false
                continue
            }

            guard !lastCharacterWasSeparator else {
                continue
            }

            sanitizedSuffix.append("-")
            lastCharacterWasSeparator = true
        }

        sanitizedSuffix = sanitizedSuffix.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return sanitizedSuffix.isEmpty ? nil : sanitizedSuffix
    }
}
