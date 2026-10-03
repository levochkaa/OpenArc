import Foundation
import Network

/// Ephemeral loopback Basic authentication. Request evidence records only the
/// classification of the fixture credential, never the Authorization value.
@MainActor final class BasicAuthHTTPFixture {
    // MARK: Lifecycle

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
    }

    // MARK: Internal

    enum Authorization: Equatable, Sendable { case missing, invalid, valid }

    struct Request: Sendable {
        let method: String
        let path: String
        let authorization: Authorization
    }

    static let username = "test-user"
    static let password = "test-password"

    private(set) var requests = [Request]()
    private(set) var parseErrors = [String]()

    var protectedRequests: [Request] { requests.filter { Self.route($0.path) == "/protected" } }
    var unauthenticatedRequestCount: Int { protectedRequests.filter { $0.authorization == .missing }.count }
    var invalidAuthorizationRequestCount: Int { protectedRequests.filter { $0.authorization == .invalid }.count }
    var authenticatedRequestCount: Int { protectedRequests.filter { $0.authorization == .valid }.count }

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

    private static let maximumRequestBytes = 1024 * 1024
    private static let maximumHeaderBytes = 16 * 1024

    private let listener: NWListener
    private var started = false
    private var stopped = false
    private var connections = [ObjectIdentifier: NWConnection]()
    private var connectionTimeouts = [ObjectIdentifier: Task<Void, Never>]()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?

    private static func route(_ path: String) -> String {
        String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private static func classify(_ value: String?) -> Authorization {
        guard let value else { return .missing }
        let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: String(parts[1])),
              decoded == Data("\(username):\(password)".utf8) else { return .invalid }
        return .valid
    }

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
                guard bytes.count <= Self.maximumRequestBytes else {
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
                    guard headers[name] == nil else { reject("Duplicate header field", on: connection)
                        return
                    }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil else {
                    reject("Transfer-Encoding is unsupported", on: connection)
                    return
                }
                if let length = headers["content-length"] {
                    guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), Int(length) == 0 else {
                        reject("This GET fixture does not accept request bodies", on: connection)
                        return
                    }
                }
                guard bytes.count == separator.upperBound else {
                    reject("Unexpected request body", on: connection)
                    return
                }
                let request = Request(
                    method: String(first[0]),
                    path: String(first[1]),
                    authorization: Self.classify(headers["authorization"])
                )
                requests.append(request)
                respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        guard request.method == "GET" else {
            response(title: "Method not allowed", status: "405 Method Not Allowed", on: connection)
            return
        }
        switch Self.route(request.path) {
        case "/public":
            response(title: "Public page", on: connection)
        case "/protected":
            if request.authorization == .valid {
                response(title: "Authenticated page", on: connection)
            } else {
                response(
                    title: "Authentication required",
                    status: "401 Unauthorized",
                    extra: "WWW-Authenticate: Basic realm=\"Fixture\"\r\n",
                    on: connection
                )
            }
        default:
            response(title: "Not found", status: "404 Not Found", on: connection)
        }
    }

    private func reject(_ reason: String, on connection: NWConnection) {
        parseErrors.append(reason)
        response(title: "Bad request", status: "400 Bad Request", on: connection)
    }

    private func response(title: String, status: String = "200 OK", extra: String = "", on connection: NWConnection) {
        connectionTimeouts.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        let body = Data(
            "<!doctype html><meta name='viewport' content='width=device-width, initial-scale=1'><title>\(title)</title><h1>\(title)</h1>"
                .utf8
        )
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
        })
    }
}
