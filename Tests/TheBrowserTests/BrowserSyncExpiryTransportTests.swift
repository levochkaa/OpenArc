import Foundation
import Synchronization
import Testing

// MARK: - BrowserSyncExpiryTransportTests

@Suite(.serialized) struct BrowserSyncExpiryTransportTests {
    @Test @MainActor func expiryUsesConditionalWireEnvelopeAndValidatesTheHTTPReceipt() async throws {
        let mutation = expiryTransportMutation()
        let response = expiryTransportReceipt(mutation: mutation)
        ExpiryURLProtocol.state.withLock { $0 = .init(response: try! JSONEncoder().encode(response)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExpiryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let baseURL = try #require(URL(string: "https://expiry-transport.example"))
        let client = try BrowserRemoteSyncClient(configuration: #require(.init(baseURL: baseURL)), session: session)
        let auth = BrowserAuthSession(
            accessToken: "fixture-only", userID: "owner", userEmail: nil,
            deviceID: "device", serverURL: baseURL
        )
        #expect(try await client.push(mutation: mutation, authSession: auth) == response)
        let requests = ExpiryURLProtocol.state.withLock { $0.requests }
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/sync/push")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
        let data = try #require(request.httpBody ?? expiryRequestBody(request.httpBodyStream))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["protocolVersion", "mutationID", "deviceID", "operations"])
        #expect(body["protocolVersion"] as? Int == 5)
        #expect(body["mutationID"] as? String == mutation.id)
        #expect(body["deviceID"] as? String == "device")
        let operations = try #require(body["operations"] as? [[String: Any]])
        #expect(operations.count == 1)
        #expect(Set(operations[0].keys) == [
            "kind",
            "entityType",
            "entityID",
            "expectedServerSeq",
            "inactiveForSeconds",
        ])
        #expect(operations[0]["kind"] as? String == "expire")
        #expect(operations[0]["entityType"] as? String == "tab")
        #expect(operations[0]["entityID"] as? String == "tab")
        #expect(operations[0]["expectedServerSeq"] as? Int == 2)
        #expect(operations[0]["inactiveForSeconds"] as? Int == 43200)

        let malformed = BrowserSyncExpiryPushResponse(
            protocolVersion: 5, mutationID: UUID().uuidString, cursor: response.cursor,
            events: response.events, outcomes: response.outcomes
        )
        ExpiryURLProtocol.state.withLock { $0.response = try! JSONEncoder().encode(malformed) }
        await #expect(throws: BrowserRemoteSyncError.self) {
            try await client.push(mutation: mutation, authSession: auth)
        }
        let otherURL = try #require(URL(string: "https://other.example"))
        let wrongServer = BrowserAuthSession(
            accessToken: "must-not-send", userID: "owner", userEmail: nil,
            deviceID: "device", serverURL: otherURL
        )
        await #expect(throws: BrowserSyncAccountError.self) {
            try await client.push(mutation: mutation, authSession: wrongServer)
        }
        #expect(ExpiryURLProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test(arguments: ExpiryMalformedReceipt.allCases)
    func malformedReceiptsCannotAcknowledgeAConditionalIntent(_ defect: ExpiryMalformedReceipt) throws {
        let mutation = expiryTransportMutation()
        let valid = expiryTransportReceipt(mutation: mutation)
        var version = 5
        var id = mutation.id
        var cursor = valid.cursor
        var events = valid.events
        var outcomes = valid.outcomes
        switch defect {
        case .wrongVersion: version = 4
        case .wrongMutation: id = UUID().uuidString
        case .negativeCursor: cursor = -1
        case .unsafeCursor: cursor = 9_007_199_254_740_992
        case .missingOutcome: outcomes = []
        case .duplicateOutcome: outcomes += outcomes
        case .wrongIndex: outcomes = [.init(operationIndex: 1, status: .applied, reason: nil)]
        case .missingEvent: events = []
        case .duplicateEvent: events += events
        case .unrelatedID: events = [expiryTransportDelete(id: "other")]
        case .zeroSequence: events = [expiryTransportDelete(sequence: 0)]
        case .beyondCursor: events = [expiryTransportDelete(sequence: 4)]
        case .wrongSourceSequence: events = [expiryTransportDelete(sourceSequence: 1)]
        case .manualApplied: events = [expiryTransportDelete(recovery: false)]
        case .appliedWithReason: outcomes = [.init(operationIndex: 0, status: .applied, reason: .stateChanged)]
        case .deletedWithoutEvent:
            outcomes = [.init(operationIndex: 0, status: .deleted, reason: nil)]
            events = []
        case .rejectedWithoutReason: outcomes = [.init(operationIndex: 0, status: .rejected, reason: nil)]
        case .rejectedWithDelete: outcomes = [.init(operationIndex: 0, status: .rejected, reason: .stateChanged)]
        case .responseLimitWithEvent:
            outcomes = [.init(operationIndex: 0, status: .rejected, reason: .responseLimit)]
        }
        let response = BrowserSyncExpiryPushResponse(
            protocolVersion: version, mutationID: id, cursor: cursor, events: events, outcomes: outcomes
        )
        #expect(throws: (any Error).self) { try response.validate(for: mutation) }
    }

    @Test func terminalRejectionsAndExistingManualDeletionAreValidReceipts() throws {
        let mutation = expiryTransportMutation()
        for reason in [BrowserSyncExpiryOutcome.Reason.missing, .responseLimit] {
            try BrowserSyncExpiryPushResponse(
                protocolVersion: 5, mutationID: mutation.id, cursor: 2, events: [],
                outcomes: [.init(operationIndex: 0, status: .rejected, reason: reason)]
            ).validate(for: mutation)
        }
        try BrowserSyncExpiryPushResponse(
            protocolVersion: 5, mutationID: mutation.id, cursor: 3,
            events: [expiryTransportDelete(recovery: false)],
            outcomes: [.init(operationIndex: 0, status: .deleted, reason: nil)]
        ).validate(for: mutation)
    }

    @Test func invalidExpiryIntentIsRejectedBeforeEncodingOrQueueAdmission() throws {
        let valid = expiryTransportMutation()
        for operations in [
            [], valid.operations + valid.operations,
            [.init(id: "tab", expectedServerSeq: 0, inactiveForSeconds: 43200)],
            [.init(id: "tab", expectedServerSeq: 9_007_199_254_740_992, inactiveForSeconds: 43200)],
            [.init(id: "tab", expectedServerSeq: 2, inactiveForSeconds: 1)],
            (0...100)
                .map { BrowserSyncExpiryOperation(id: "tab-\($0)", expectedServerSeq: 2, inactiveForSeconds: 43200) },
        ] as [[BrowserSyncExpiryOperation]] {
            #expect(throws: BrowserSyncExpiryError.self) {
                try BrowserSyncExpiryMutation(id: valid.id, operations: operations).validate()
            }
        }
        #expect(throws: BrowserSyncQueueError.self) {
            try BrowserSyncExpiryMutation(id: "not-a-uuid", operations: valid.operations).validate()
        }
        let encoded = try JSONEncoder().encode(expiryTransportReceipt(mutation: valid))
        let unknownReason = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"applied\"", with: "\"future-status\"")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BrowserSyncExpiryPushResponse.self, from: Data(unknownReason.utf8))
        }
    }
}

// MARK: - ExpiryMalformedReceipt

enum ExpiryMalformedReceipt: CaseIterable {
    case wrongVersion, wrongMutation, negativeCursor, unsafeCursor, missingOutcome, duplicateOutcome, wrongIndex
    case missingEvent, duplicateEvent, unrelatedID, zeroSequence, beyondCursor, wrongSourceSequence, manualApplied
    case appliedWithReason, deletedWithoutEvent, rejectedWithoutReason, rejectedWithDelete, responseLimitWithEvent
}

private func expiryTransportMutation() -> BrowserSyncExpiryMutation {
    .init(id: UUID().uuidString, operations: [.init(id: "tab", expectedServerSeq: 2, inactiveForSeconds: 43200)])
}

private func expiryTransportReceipt(mutation: BrowserSyncExpiryMutation) -> BrowserSyncExpiryPushResponse {
    .init(
        protocolVersion: 5, mutationID: mutation.id, cursor: 3, events: [expiryTransportDelete()],
        outcomes: [.init(operationIndex: 0, status: .applied, reason: nil)]
    )
}

private func expiryTransportDelete(
    id: String = "tab", sequence: Int = 3, sourceSequence: Int = 2, recovery: Bool = true
) -> BrowserSyncEvent {
    let tab = BrowserSyncEventTabData(
        id: id, spaceID: "work", placement: .temporary, rank: 0,
        urlString: "https://example.com/expired", pinnedURLString: nil, title: "Expired",
        userTitleOverride: nil, faviconURLString: nil, lastActivityAt: "2000-01-01T00:00:00Z", pinnedFolderID: nil
    )
    return .init(
        serverSeq: sequence, deviceID: "remote", entityType: "tab", entityID: id, op: "delete",
        data: .deleted(
            id: id,
            autoArchive: recovery
                ? .init(
                    archivedAt: "2026-10-03T12:00:00.123456Z", sourceServerSeq: sourceSequence, tab: tab
                )
                : nil
        ), createdAt: "2026-10-03T12:00:00Z"
    )
}

private func expiryRequestBody(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 {
            return count == 0 ? result : nil
        }
        result.append(contentsOf: buffer.prefix(count))
    }
}

// MARK: - ExpiryURLProtocol

private final class ExpiryURLProtocol: URLProtocol, @unchecked Sendable {
    struct State { var response: Data
        var requests = [URLRequest]()
    }

    static let state = Mutex(State(response: Data()))

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "expiry-transport.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        captured.httpBody = request.httpBody ?? expiryRequestBody(request.httpBodyStream)
        let data = Self.state.withLock { state in
            state.requests.append(captured)
            return state.response
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/json",
        ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
