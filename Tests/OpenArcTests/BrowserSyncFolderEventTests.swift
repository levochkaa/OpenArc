// BrowserSyncFolderEventTests.swift

import Foundation
import Testing

@Test func syncEventEnvelopeDisambiguatesTitlesAndFolderMembership() throws {
    let wire = #"[{"serverSeq":1,"deviceID":null,"entityType":"space","entityID":"same","op":"upsert","data":{"id":"same","title":"Work","systemImageName":"globe","rank":0,"isPinnedSectionCollapsed":false},"createdAt":"2026-10-03T00:00:00Z"},{"serverSeq":2,"deviceID":null,"entityType":"folder","entityID":"same","op":"upsert","data":{"id":"same","spaceID":"same","parentFolderID":null,"title":"Folder","systemImageName":null,"rank":0},"createdAt":"2026-10-03T00:00:00Z"},{"serverSeq":3,"deviceID":null,"entityType":"tab","entityID":"same","op":"upsert","data":{"id":"same","spaceID":"same","placement":"spacePinned","pinnedFolderID":"same","urlString":"https://example.test","title":"Page title","rank":0},"createdAt":"2026-10-03T00:00:00Z"}]"#
    let events = try JSONDecoder().decode([BrowserSyncEvent].self, from: Data(wire.utf8))
    guard case .space = events[0].data,
          case .folder(let folder) = events[1].data,
          case .tab(let tab) = events[2].data
    else {
        Issue.record("Entity envelopes must determine payload types even when IDs and title keys match")
        return
    }
    #expect(folder.title == "Folder" && folder.parentFolderID == nil)
    #expect(tab.title == "Page title" && tab.pinnedFolderID == "same")
    #expect(try JSONDecoder().decode([BrowserSyncEvent].self, from: JSONEncoder().encode(events)) == events)
    var baseline = BrowserSyncOutboxBaseline()
    try baseline.apply(events)
    #expect(baseline.entities.count == 3)
    #expect(baseline.entities["folder:same"]?.change.folderData?.title == "Folder")
    #expect(baseline.entities["tab:same"]?.change.tabData?.pinnedFolderID == "same")
}

@Test func legacyPayloadEncodingStillOmitsFolderMembership() throws {
    let change = BrowserSyncChange(
        entityType: .tab, entityID: "legacy", op: .upsert, spaceData: nil,
        tabData: .init(
            spaceID: "space",
            placement: .spacePinned,
            rank: 0,
            urlString: "https://example.test",
            pinnedURLString: nil,
            title: nil,
            userTitleOverride: nil,
            faviconURLString: nil,
            lastActivityAt: nil,
        ),
    )
    let encoded = try JSONEncoder().encode(BrowserSyncMutation(id: "frozen", changes: [change]))
    #expect(!String(decoding: encoded, as: UTF8.self).contains("pinnedFolderID"))
    #expect(try JSONDecoder().decode(BrowserSyncMutation.self, from: encoded).changes == [change])
}
