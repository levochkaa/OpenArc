import Foundation
import Network

/// Disposable loopback pages and raw upload capture. This fixture deliberately
/// accepts bounded Content-Length requests only; it never guesses chunked bytes.
@MainActor final class UploadHTTPFixture {
    // MARK: Lifecycle

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    // MARK: Internal

    struct Request {
        // MARK: Internal

        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        func multipartParts() throws -> [Part] {
            guard body.count <= 1024 * 1024 else { throw MultipartError.invalidBody }
            let boundary = try Self.boundary(in: headers["content-type"])
            let marker = Data(("--" + boundary).utf8)
            let nextMarker = Data("\r\n".utf8) + marker
            let newline = Data("\r\n".utf8)
            let final = Data("--\r\n".utf8)
            let headerEnd = Data("\r\n\r\n".utf8)
            guard body.starts(with: marker) else { throw MultipartError.invalidBody }
            var offset = marker.count
            var parts = [Part]()
            while true {
                if body[offset...].starts(with: final) {
                    guard offset + final.count == body.count else { throw MultipartError.invalidBody }
                    return parts
                }
                guard body[offset...].starts(with: newline) else { throw MultipartError.invalidBody }
                offset += newline.count
                guard let separator = body.range(of: headerEnd, in: offset..<body.count),
                      separator.lowerBound - offset <= 16 * 1024,
                      let headerText = String(data: body[offset..<separator.lowerBound], encoding: .utf8)
                else {
                    throw MultipartError.invalidHeaders
                }
                let partHeaders = try Self.partHeaders(headerText)
                let payloadStart = separator.upperBound
                var searchStart = payloadStart
                var delimiter: Range<Int>?
                while let candidate = body.range(of: nextMarker, in: searchStart..<body.count) {
                    let suffix = body[candidate.upperBound...]
                    if suffix.starts(with: newline) || suffix.starts(with: final) {
                        delimiter = candidate
                        break
                    }
                    // A boundary-like sequence with a different suffix belongs
                    // to the binary file; only an exact delimiter ends a part.
                    searchStart = candidate.upperBound
                }
                guard let delimiter else { throw MultipartError.invalidBody }
                parts.append(.init(headers: partHeaders, body: Data(body[payloadStart..<delimiter.lowerBound])))
                offset = delimiter.upperBound
            }
        }

        // MARK: Private

        private static func partHeaders(_ text: String) throws -> [String: String] {
            var result = [String: String]()
            for line in text.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                      line[..<colon].utf8.allSatisfy(isToken),
                      line.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 || $0.value == 9 })
                else {
                    throw MultipartError.invalidHeaders
                }
                let name = line[..<colon].lowercased()
                guard result[name] == nil else { throw MultipartError.invalidHeaders }
                result[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard !result.isEmpty else { throw MultipartError.invalidHeaders }
            return result
        }

        private static func boundary(in contentType: String?) throws -> String {
            guard let contentType, contentType.utf8.count <= 16 * 1024,
                  let separator = contentType.firstIndex(of: ";"),
                  contentType[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "multipart/form-data"
            else { throw MultipartError.invalidContentType }
            let bytes = Array(contentType[contentType.index(after: separator)...].utf8)
            var offset = 0
            var parameters = [String: String]()
            while offset < bytes.count {
                while offset < bytes.count, bytes[offset] == 32 || bytes[offset] == 9 {
                    offset += 1
                }
                let nameStart = offset
                while offset < bytes.count, isToken(bytes[offset]) {
                    offset += 1
                }
                guard offset > nameStart else { throw MultipartError.invalidContentType }
                let name = String(decoding: bytes[nameStart..<offset], as: UTF8.self).lowercased()
                while offset < bytes.count, bytes[offset] == 32 || bytes[offset] == 9 {
                    offset += 1
                }
                guard offset < bytes.count, bytes[offset] == 61 else { throw MultipartError.invalidContentType }
                offset += 1
                while offset < bytes.count, bytes[offset] == 32 || bytes[offset] == 9 {
                    offset += 1
                }
                var value = [UInt8]()
                if offset < bytes.count, bytes[offset] == 34 {
                    offset += 1
                    while offset < bytes.count, bytes[offset] != 34 {
                        if bytes[offset] == 92 {
                            offset += 1
                        }
                        guard offset < bytes.count, (32...126).contains(bytes[offset]) else {
                            throw MultipartError.invalidContentType
                        }
                        value.append(bytes[offset])
                        offset += 1
                    }
                    guard offset < bytes.count, bytes[offset] == 34 else { throw MultipartError.invalidContentType }
                    offset += 1
                } else {
                    while offset < bytes.count, isToken(bytes[offset]) {
                        value.append(bytes[offset])
                        offset += 1
                    }
                    guard !value.isEmpty else { throw MultipartError.invalidContentType }
                }
                guard parameters[name] == nil else { throw MultipartError.invalidContentType }
                parameters[name] = String(decoding: value, as: UTF8.self)
                while offset < bytes.count, bytes[offset] == 32 || bytes[offset] == 9 {
                    offset += 1
                }
                if offset < bytes.count {
                    guard bytes[offset] == 59, offset + 1 < bytes.count else { throw MultipartError.invalidContentType }
                    offset += 1
                }
            }
            guard let boundary = parameters["boundary"], !boundary.isEmpty, boundary.utf8.count <= 70,
                  boundary.utf8.last != 32,
                  boundary.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                          || Array("'()+_,-./:=? ".utf8).contains(byte)
                  }) else { throw MultipartError.invalidContentType }
            return boundary
        }

        private static func isToken(_ byte: UInt8) -> Bool {
            (33...126).contains(byte) && !Array("()<>@,;:\\\"/[]?={}".utf8).contains(byte)
        }
    }

    struct Part {
        let headers: [String: String]
        let body: Data
    }

    enum MultipartError: Error, Equatable {
        case invalidContentType, invalidHeaders, invalidBody
    }

    private(set) var requests = [Request]()
    private(set) var parseErrors = [String]()

    func start() async throws {
        guard !started, !stopped else { throw URLError(.cannotConnectToHost) }
        started = true
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, !stopped else { return }
                    switch state {
                    case .ready: finishStarting()
                    case .failed(let error), .waiting(let error): finishStarting(error: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, !stopped else { connection.cancel()
                        return
                    }
                    let id = ObjectIdentifier(connection)
                    connections[id] = connection
                    connection.start(queue: .main)
                    connectionTimeouts[id] = Task { @MainActor [weak self, weak connection] in
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        guard let self, let connection, connections[id] != nil else { return }
                        reject("Request timed out", on: connection)
                    }
                    receive(connection, accumulated: Data())
                }
            }
            listener.start(queue: .main)
            startTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.finishStarting(error: URLError(.timedOut))
            }
        }
    }

    func url(_ path: String) throws -> URL {
        guard !stopped, path.hasPrefix("/"), let port = listener.port,
              let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")
        else {
            throw URLError(.badURL)
        }
        return url
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        finishStarting(error: URLError(.cancelled))
        for timeout in connectionTimeouts.values {
            timeout.cancel()
        }
        connectionTimeouts.removeAll()
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        listener.cancel()
    }

    // MARK: Private

    private static let maximumBodyBytes = 1024 * 1024
    private static let maximumHeaderBytes = 16 * 1024

    private let listener: NWListener
    private var started = false
    private var stopped = false
    private var connections = [ObjectIdentifier: NWConnection]()
    private var connectionTimeouts = [ObjectIdentifier: Task<Void, Never>]()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?

    private func finishStarting(error: Error? = nil) {
        startTimeout?.cancel()
        startTimeout = nil
        let continuation = startContinuation
        startContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
            listener.cancel()
        } else {
            continuation?.resume()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, !stopped, connections[ObjectIdentifier(connection)] != nil else {
                    connection.cancel()
                    return
                }
                var bytes = accumulated
                if let data {
                    bytes.append(data)
                }
                guard error == nil else { reject("Transport error while reading request", on: connection)
                    return
                }
                guard bytes.count <= Self.maximumBodyBytes + Self.maximumHeaderBytes else {
                    reject("Request exceeds byte limit", on: connection)
                    return
                }
                guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                    guard bytes.count <= Self.maximumHeaderBytes else {
                        reject("Headers exceed byte limit", on: connection)
                        return
                    }
                    if complete {
                        reject("Truncated request headers", on: connection)
                    } else {
                        receive(connection, accumulated: bytes)
                    }
                    return
                }
                guard separator.upperBound <= Self.maximumHeaderBytes,
                      let text = String(data: bytes[..<separator.lowerBound], encoding: .utf8)
                else {
                    reject("Invalid request headers", on: connection)
                    return
                }
                let lines = text.components(separatedBy: "\r\n")
                let first = (lines.first ?? "").split(separator: " ")
                guard first.count == 3, first[2].hasPrefix("HTTP/1."), first[1].hasPrefix("/") else {
                    reject("Invalid request line", on: connection)
                    return
                }
                var headers = [String: String]()
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                          !line.hasPrefix(" "), !line.hasPrefix("\t")
                    else {
                        reject("Invalid header field", on: connection)
                        return
                    }
                    let name = String(line[..<colon]).lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard headers[name] == nil else {
                        reject("Duplicate header field", on: connection)
                        return
                    }
                    headers[name] = value
                }
                guard headers["transfer-encoding"] == nil else {
                    reject("Transfer-Encoding is unsupported; Content-Length is required", on: connection)
                    return
                }
                let method = String(first[0])
                let length: Int
                if let raw = headers["content-length"] {
                    guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                          let parsed = Int(raw), parsed <= Self.maximumBodyBytes
                    else {
                        reject("Invalid or oversized Content-Length", on: connection)
                        return
                    }
                    length = parsed
                } else {
                    guard method != "POST" else {
                        reject("POST requires Content-Length", on: connection)
                        return
                    }
                    length = 0
                }
                let body = bytes[separator.upperBound...]
                guard body.count >= length else {
                    if complete {
                        reject("Truncated request body", on: connection)
                    } else {
                        receive(connection, accumulated: bytes)
                    }
                    return
                }
                let request = Request(
                    method: method,
                    path: String(first[1]),
                    headers: headers,
                    body: Data(body.prefix(length))
                )
                requests.append(request)
                respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/source"):
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Upload source</title><style>body{font:18px system-ui;padding:16px}form{margin:24px 0}input,button{font:inherit;margin:8px 0;max-width:100%}</style></head><body>
            <form id="singleform" action="/submit" method="POST" enctype="multipart/form-data">
            <label for="single">Choose one text file</label><br>
            <input id="single" name="files" type="file" accept="text/plain">
            <input type="hidden" name="token" value="upload-fixture"><br><button type="submit">Submit single</button></form>
            <form id="multipleform" action="/submit" method="POST" enctype="multipart/form-data">
            <label for="multiple">Choose text files</label><br>
            <input id="multiple" name="files" type="file" accept="text/plain" multiple>
            <input type="hidden" name="token" value="upload-fixture"><br><button type="submit">Submit multiple</button></form>
            <a id="next" href="/next">Next page</a>
            <script>window.selectionChanges={single:0,multiple:0};for(const id of ['single','multiple'])document.getElementById(id).addEventListener('change',()=>window.selectionChanges[id]++);</script>
            </body></html>
            """
            response(html, extra: "Set-Cookie: upload-token=kept; SameSite=Lax; Path=/\r\n", on: connection)
        case ("GET", "/next"):
            response(
                "<!doctype html><meta name='viewport' content='width=device-width, initial-scale=1'><title>Upload next</title>Next page",
                on: connection
            )
        case ("POST", "/submit"):
            response("<!doctype html><title>Upload received</title>Upload received", on: connection)
        default:
            response("Not found", status: "404 Not Found", on: connection)
        }
    }

    private func reject(_ reason: String, on connection: NWConnection) {
        parseErrors.append(reason)
        response("Bad request", status: "400 Bad Request", on: connection)
    }

    private func response(_ html: String, status: String = "200 OK", extra: String = "", on connection: NWConnection) {
        connectionTimeouts.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        let body = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
        })
    }
}
