// BrowserToolbarConfigurationTests.swift

import CoreGraphics
import Testing

@Test func toolbarItemsRoundTripThroughStorageAndUnknownOnesAreDropped() {
    let configuration = BrowserToolbarConfiguration(items: [.back, .command(.zoomIn), .flexibleSpace, .address])
    #expect(BrowserToolbarConfiguration(storedValues: configuration.storedValues) == configuration)
    #expect(BrowserToolbarConfiguration(storedValues: ["back", "from-the-future", "command:nope"]).items == [.back])
}

@Test func onlyAFlexibleSpaceCanRepeat() {
    var configuration = BrowserToolbarConfiguration(items: [.back, .back, .flexibleSpace, .flexibleSpace])
    #expect(configuration.items == [.back, .flexibleSpace, .flexibleSpace])
    #expect(configuration.availableItems.contains(.flexibleSpace))
    #expect(!configuration.availableItems.contains(.back))
    configuration.insert(.back, at: 3)
    #expect(configuration.items == [.flexibleSpace, .flexibleSpace, .back], "Inserting an item already there moves it")
}

@Test func movingCountsTheBarAsTheDropIndicatorShowsIt() {
    var configuration = BrowserToolbarConfiguration(items: [.back, .forward, .reload])
    configuration.move(from: 0, to: 2)
    #expect(configuration.items == [.forward, .back, .reload])
    configuration.move(from: 2, to: 0)
    #expect(configuration.items == [.reload, .forward, .back])
    configuration.remove(at: 1)
    #expect(configuration.items == [.reload, .back])
    configuration.remove(at: 9)
    #expect(configuration.items == [.reload, .back])
}

@Test func twoFlexibleSpacesCenterWhatIsBetweenThem() {
    let spans = BrowserToolbarConfiguration.spans(
        for: [30, 30, nil, 200, nil, 60],
        spacing: 0,
        padding: 0,
        length: 600,
    )
    let address = spans[3]
    #expect(address.start + address.width / 2 == 300, "Uneven sides still center the address")
    #expect(spans.last.map { $0.start + $0.width } == 600)

    let tight = BrowserToolbarConfiguration.spans(for: [300, nil, 100, nil, 10], spacing: 0, padding: 0, length: 420)
    #expect(tight[2].start >= 300, "Items never overlap when the center doesn't fit")
    #expect(tight.last.map { $0.start + $0.width } == 420)
}

@Test func aDropLandsInTheNearestGap() {
    let frames = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 0, width: 10, height: 10)]
    #expect(BrowserToolbarEditOverlay.dropIndex(at: 2, frames: frames) == 0)
    #expect(BrowserToolbarEditOverlay.dropIndex(at: 8, frames: frames) == 1)
    #expect(BrowserToolbarEditOverlay.dropIndex(at: 99, frames: frames) == 2)
}
