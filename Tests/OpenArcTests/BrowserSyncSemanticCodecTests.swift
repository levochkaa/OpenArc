import Foundation
import Testing

@Test func semanticMutationRoundtripsEveryOperationWithoutNumericRanks() throws {
    let operations: [BrowserSyncSemanticOperation] = [
        .createSpace(id: "work", data: .init(title: "Work", systemImageName: "briefcase"), beforeID: "personal"),
        .createTab(
            id: "tab",
            data: .init(spaceID: "work", placement: .temporary, urlString: "https://example.test"),
            afterID: "previous"
        ),
        .patchSpace(
            id: "work",
            fields: .init(title: "Renamed", isPinnedSectionCollapsed: false, selectedTabID: .clear)
        ),
        .patchTab(id: "tab", fields: .init(userTitleOverride: .set("Renamed tab"), faviconURLString: .clear)),
        .moveSpaces(ids: ["work", "personal"], beforeID: "other"),
        .moveTabs(
            ids: ["b", "a"],
            destination: .init(spaceID: "personal", placement: .spacePinned),
            afterID: "neighbor"
        ),
        .deleteSpace(id: "old-space"),
        .deleteTab(id: "old-tab"),
    ]
    let mutation = BrowserSyncSemanticMutation(id: "mutation", operations: operations)
    let restored = try JSONDecoder().decode(BrowserSyncSemanticMutation.self, from: JSONEncoder().encode(mutation))
    #expect(restored == mutation)

    let request = BrowserSyncSemanticPushRequest(mutationID: mutation.id, deviceID: "device", operations: operations)
    let encoded = try JSONEncoder().encode(request)
    #expect(try JSONDecoder().decode(BrowserSyncSemanticPushRequest.self, from: encoded) == request)
    let body = try semanticJSONObject(encoded)
    #expect(body["protocolVersion"] as? Int == 3)
    #expect(body["mutationID"] as? String == "mutation")
    #expect(body["changes"] == nil)
    let wireOperations = try #require(body["operations"] as? [[String: Any]])
    #expect(wireOperations.map { $0["kind"] as? String } == [
        "create",
        "create",
        "patch",
        "patch",
        "move",
        "move",
        "delete",
        "delete",
    ])
    #expect((wireOperations[5]["entityIDs"] as? [String]) == ["b", "a"])
    #expect(wireOperations[5]["entityID"] == nil)
    #expect(wireOperations[4]["destination"] == nil)
    #expect(wireOperations[0]["beforeID"] as? String == "personal")
    #expect(wireOperations[1]["afterID"] as? String == "previous")
    for operation in wireOperations {
        #expect((operation["data"] as? [String: Any])?["rank"] == nil)
        #expect((operation["fields"] as? [String: Any])?["rank"] == nil)
    }
}

@Test func semanticTabPatchPreservesMissingNullAndValueAsDifferentIntents() throws {
    let empty = try JSONDecoder().decode(BrowserSyncSemanticTabPatch.self, from: Data("{}".utf8))
    let clear = try JSONDecoder().decode(
        BrowserSyncSemanticTabPatch.self,
        from: Data(#"{"userTitleOverride":null}"#.utf8)
    )
    let set = try JSONDecoder().decode(
        BrowserSyncSemanticTabPatch.self,
        from: Data(#"{"userTitleOverride":"Named"}"#.utf8)
    )
    #expect(empty.userTitleOverride == .unchanged)
    #expect(clear.userTitleOverride == .clear)
    #expect(set.userTitleOverride == .set("Named"))
    #expect(empty != clear)
    #expect(clear != set)
    #expect(try semanticJSONObject(JSONEncoder().encode(empty)).isEmpty)
    #expect(try semanticJSONObject(JSONEncoder().encode(clear))["userTitleOverride"] is NSNull)
    #expect(try semanticJSONObject(JSONEncoder().encode(set))["userTitleOverride"] as? String == "Named")

    let patch = BrowserSyncSemanticTabPatch(
        urlString: "https://new.example", pinnedURLString: .clear, title: .set("Title"),
        userTitleOverride: .unchanged, faviconURLString: .clear, lastActivityAt: .set("2026-10-03T00:00:00Z")
    )
    #expect(try JSONDecoder().decode(BrowserSyncSemanticTabPatch.self, from: JSONEncoder().encode(patch)) == patch)
    let body = try semanticJSONObject(JSONEncoder().encode(patch))
    #expect(Set(body.keys) == ["urlString", "pinnedURLString", "title", "faviconURLString", "lastActivityAt"])
    #expect(body["pinnedURLString"] is NSNull)
    #expect(body["userTitleOverride"] == nil)
    #expect(body["spaceID"] == nil)
    #expect(body["placement"] == nil)
}

@Test func semanticSpacePatchPreservesFalseAndNullableSelection() throws {
    let patch = BrowserSyncSemanticSpacePatch(isPinnedSectionCollapsed: false, selectedTabID: .clear)
    let data = try JSONEncoder().encode(patch)
    let body = try semanticJSONObject(data)
    #expect(body["isPinnedSectionCollapsed"] as? Bool == false)
    #expect(body["selectedTabID"] is NSNull)
    #expect(body["title"] == nil)
    #expect(try JSONDecoder().decode(BrowserSyncSemanticSpacePatch.self, from: data) == patch)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(BrowserSyncSemanticSpacePatch.self, from: Data(#"{"title":null}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(BrowserSyncSemanticTabPatch.self, from: Data(#"{"urlString":null}"#.utf8))
    }
}

@Test func semanticMoveNullAnchorsDecodeToAppendFallbackWithoutLosingGroupOrder() throws {
    let json = Data(
        #"{"kind":"move","entityType":"tab","entityIDs":["b","a"],"destination":{"spaceID":"work","placement":"temporary"},"beforeID":null,"afterID":null}"#
            .utf8
    )
    let operation = try JSONDecoder().decode(BrowserSyncSemanticOperation.self, from: json)
    #expect(operation == .moveTabs(ids: ["b", "a"], destination: .init(spaceID: "work", placement: .temporary)))
    let body = try semanticJSONObject(JSONEncoder().encode(operation))
    #expect(body["beforeID"] == nil)
    #expect(body["afterID"] == nil)
    #expect(body["entityIDs"] as? [String] == ["b", "a"])
}

@Test func semanticReceiptDecodesTypedOutcomesAndRejectsUnknownStatus() throws {
    let json = Data(
        #"{"protocolVersion":3,"mutationID":"mutation","cursor":9,"events":[{"serverSeq":9,"deviceID":null,"entityType":"tab","entityID":"gone","op":"delete","data":{"id":"gone"},"createdAt":"2026-10-03T00:00:00Z"}],"outcomes":[{"operationIndex":0,"status":"applied"},{"operationIndex":1,"status":"deleted"},{"operationIndex":2,"status":"rejected","reason":"destinationDeleted"}]}"#
            .utf8
    )
    let receipt = try JSONDecoder().decode(BrowserSyncSemanticPushResponse.self, from: json)
    #expect(receipt.outcomes.map(\.status) == [.applied, .deleted, .rejected])
    #expect(receipt.outcomes[2].reason == "destinationDeleted")
    #expect(try JSONDecoder()
        .decode(BrowserSyncSemanticPushResponse.self, from: JSONEncoder().encode(receipt)) == receipt)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            BrowserSyncSemanticOutcome.self,
            from: Data(#"{"operationIndex":0,"status":"future-status"}"#.utf8)
        )
    }
}

@Test func semanticPullCapabilitiesRemainAdditiveForLegacyResponses() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(BrowserSyncPullResponse.self, from: Data(#"{"cursor":0,"events":[]}"#.utf8))
    #expect(legacy.protocolVersion == nil)
    #expect(legacy.supportedPushVersions == nil)
    let durable = try decoder.decode(
        BrowserSyncPullResponse.self,
        from: Data(#"{"protocolVersion":2,"cursor":0,"events":[]}"#.utf8)
    )
    #expect(durable.protocolVersion == 2)
    #expect(durable.supportedPushVersions == nil)
    let semantic = try decoder.decode(
        BrowserSyncPullResponse.self,
        from: Data(#"{"protocolVersion":2,"supportedPushVersions":[2,3],"cursor":0,"events":[]}"#.utf8)
    )
    #expect(semantic.protocolVersion == 2)
    #expect(semantic.supportedPushVersions == [2, 3])
}

@Test func semanticCodecDoesNotChangeLegacyV2MutationOrPushShape() throws {
    let legacy = Data(#"{"id":"immutable-id","changes":[{"entityType":"tab","entityID":"old-tab","op":"delete"}]}"#
        .utf8)
    let mutation = try JSONDecoder().decode(BrowserSyncMutation.self, from: legacy)
    let request = BrowserSyncPushRequest(mutationID: mutation.id, deviceID: "device", changes: mutation.changes)
    let encoded = try semanticJSONObject(JSONEncoder().encode(request))
    #expect(Set(encoded.keys) == ["protocolVersion", "mutationID", "deviceID", "changes"])
    #expect(encoded["protocolVersion"] as? Int == 2)
    #expect(encoded["operations"] == nil)
    #expect(try JSONDecoder().decode(BrowserSyncMutation.self, from: JSONEncoder().encode(mutation)) == mutation)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            BrowserSyncSemanticPushRequest.self,
            from: Data(#"{"protocolVersion":2,"mutationID":"id","deviceID":"device","operations":[]}"#.utf8)
        )
    }
}

@Test func semanticTransportRejectsCredentialsFromAnotherOriginBeforeSending() async throws {
    let url = try #require(URL(string: "http://127.0.0.1:1"))
    let client = try BrowserRemoteSyncClient(configuration: #require(BrowserSyncConfiguration(baseURL: url)))
    let foreign = BrowserAuthSession(
        accessToken: "unused",
        userID: "owner",
        userEmail: nil,
        deviceID: "device",
        serverURL: URL(string: "https://foreign.example")
    )
    do {
        _ = try await client.push(
            mutation: BrowserSyncSemanticMutation(id: "mutation", operations: []),
            authSession: foreign
        )
        Issue.record("Semantic transport accepted credentials from another origin")
    } catch let error as BrowserSyncAccountError {
        #expect(error == .serverChanged)
    }
}

private func semanticJSONObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
