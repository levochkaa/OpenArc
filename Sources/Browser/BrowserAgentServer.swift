// BrowserAgentServer.swift

import Darwin
import Foundation

// MARK: - BrowserAgentServer

/// Serves one JSON request per line on a Unix socket only this user can open.
/// Nothing listens on the network.
final class BrowserAgentServer: @unchecked Sendable {
    // MARK: Internal

    static var defaultSocketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenArc/agent.sock").path
    }

    private let path: String
    private let handler: @Sendable (String) async -> String
    private let queue = DispatchQueue(label: "com.levochkaa.OpenArc.agent-server")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String = BrowserAgentServer.defaultSocketPath, handler: @escaping @Sendable (String) async -> String) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    // MARK: Private

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    @discardableResult func start() -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = Self.address(path) else { return false }
        // Only this user may connect, from the moment the path exists.
        let previousMask = umask(0o177)
        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard didBind == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return false
        }
        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 {
            unlink(path)
            listener = -1
        }
    }

    private func acceptClient() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let handler = handler
        Task.detached {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    let response = await handler(line) + "\n"
                    let bytes = Array(response.utf8)
                    var offset = 0
                    while offset < bytes.count {
                        let written = bytes[offset...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                        guard written > 0 else { break }
                        offset += written
                    }
                }
            }
            close(client)
        }
    }
}
