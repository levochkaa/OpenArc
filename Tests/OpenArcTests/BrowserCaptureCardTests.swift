// BrowserCaptureCardTests.swift

import AppKit
import Testing

// MARK: - BrowserCaptureCardMenuTests

struct BrowserCaptureCardMenuTests {
    @Test func theMenuListsEveryWayToSendTheCaptureWithTwoDividers() {
        let menu = BrowserCaptureCardMenu()
        #expect(menu.entries == [
            .item(.toggleLibrary), .item(.copy), .item(.save), .item(.sendMessage), .divider,
            .item(.edit), .item(.retake), .divider, .item(.newEasel),
        ])
        #expect(menu.title(for: .toggleLibrary) == BrowserStrings.captureCardSaveToLibrary)
        #expect(menu.symbol(for: .toggleLibrary) == "circle")
    }

    @Test func savingToTheLibraryTurnsTheRowIntoAChecked() {
        var menu = BrowserCaptureCardMenu()
        menu.isSavedToLibrary = true
        #expect(menu.title(for: .toggleLibrary) == BrowserStrings.captureCardSavedToLibrary)
        #expect(menu.symbol(for: .toggleLibrary) == "checkmark.circle.fill")
    }

    @Test func arrowsWalkTheEnabledRowsAndStopAtTheEnds() {
        var menu = BrowserCaptureCardMenu()
        #expect(menu.selection == nil)
        menu.moveSelection(by: 1)
        #expect(menu.selection == .toggleLibrary)
        menu.moveSelection(by: -1)
        #expect(menu.selection == .toggleLibrary)
        for _ in 0..<10 {
            menu.moveSelection(by: 1)
        }
        // New Easel stays dimmed where Easels are not offered, so Retake is the last row.
        #expect(menu.selection == .retake)
        menu.canCreateEasel = true
        menu.moveSelection(by: 1)
        #expect(menu.selection == .newEasel)
    }

    @Test func typingFiltersRowsAndSelectsTheFirstMatch() {
        var menu = BrowserCaptureCardMenu()
        menu.setFilter("sav")
        #expect(menu.entries == [.item(.toggleLibrary), .item(.save)])
        #expect(menu.selection == .toggleLibrary)
        menu.moveSelection(by: 1)
        menu.setFilter("save")
        #expect(menu.selection == .save, "A selection that still matches stays")
        menu.setFilter("zzz")
        #expect(menu.entries.isEmpty)
        #expect(menu.selection == nil)
        menu.setFilter("")
        #expect(menu.entries.count == 9)
    }

    @Test func incognitoWindowsCannotSaveToTheLibrary() {
        var menu = BrowserCaptureCardMenu()
        menu.canSaveToLibrary = false
        menu.moveSelection(by: 1)
        #expect(menu.selection == .copy)
        menu.select(.toggleLibrary)
        #expect(menu.selection == .copy)
    }
}

// MARK: - BrowserCaptureCardLayoutTests

struct BrowserCaptureCardLayoutTests {
    private let page = CGRect(x: 0, y: 0, width: 1490, height: 1024)

    @Test func theMenuSitsBesideTheFrameTopAligned() {
        let picture = CGRect(x: 400, y: 300, width: 300, height: 200)
        let menu = BrowserCaptureCardView.menuFrame(besidePictureFrame: picture, height: 354, page: page)
        #expect(menu == CGRect(x: 714, y: 296, width: 273, height: 354))
    }

    @Test func theMenuMovesToTheLeadingSideNearTheTrailingEdge() {
        let picture = CGRect(x: 1100, y: 100, width: 300, height: 200)
        let menu = BrowserCaptureCardView.menuFrame(besidePictureFrame: picture, height: 354, page: page)
        #expect(abs(menu.maxX - (1100 - 4 - 10)) < 0.01)
    }

    @Test func theMenuStaysOnThePageNearTheBottom() {
        let picture = CGRect(x: 100, y: 900, width: 300, height: 100)
        let menu = BrowserCaptureCardView.menuFrame(besidePictureFrame: picture, height: 354, page: page)
        #expect(menu.maxY == page.maxY - 10)
    }

    @Test func aPictureWithoutAPlaceIsCenteredWithItsMenu() {
        let frame = BrowserCaptureCardView.centeredPictureFrame(
            size: CGSize(width: 480, height: 320),
            page: CGRect(x: 228, y: 50, width: 1490, height: 1024),
            windowTop: 0,
        )
        #expect(frame.midY == 537)
        let total = 480 + 8 + 10 + 273
        #expect(abs(frame.minX - 4 - (228 + (1490 - CGFloat(total)) / 2)) < 0.5)
    }

    @Test func largePicturesShrinkToLeaveRoomForTheMenu() {
        let size = BrowserCaptureCardView.pictureSize(pixelSize: CGSize(width: 4000, height: 1000), page: page)
        #expect(size.width <= page.width - 273 - 38)
        #expect(abs(size.width / size.height - 4) < 0.05)
        #expect(BrowserCaptureCardView.pictureSize(pixelSize: CGSize(width: 480, height: 320), page: page)
            == CGSize(width: 480, height: 320))
    }

    @Test func theMenuIsTallEnoughForItsRows() {
        #expect(BrowserCaptureCardView.menuHeight(for: BrowserCaptureCardMenu()) == 353)
    }
}

// MARK: - BrowserCaptureImagingTests

struct BrowserCaptureImagingTests {
    private static func image(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                pixels += [r, g, b, 255]
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        return provider.flatMap {
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: $0,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent,
            )
        }
    }

    @Test func cropTakesTheOutlinedFractionYDownward() throws {
        let page = try #require(Self.image(width: 100, height: 50) { _, y in y < 25 ? (255, 0, 0) : (0, 0, 255) })
        let part = try #require(BrowserCaptureImaging.crop(
            page,
            fraction: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ))
        #expect(part.width == 50)
        #expect(part.height == 25)
        let bitmap = NSBitmapImageRep(cgImage: part)
        let color = try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(color.blueComponent > 0.9 && color.redComponent < 0.1, "The lower half is blue")
        #expect(BrowserCaptureImaging.crop(page, fraction: CGRect(x: 2, y: 2, width: 1, height: 1)) == nil)
    }

    @Test func theBackdropIsGrayAtThreeQuartersOfTheBrightness() throws {
        let page = try #require(Self.image(width: 4, height: 4) { _, _ in (255, 255, 255) })
        let backdrop = try #require(BrowserCaptureImaging.backdrop(page))
        let bytes = try #require(backdrop.dataProvider?.data as Data?)
        #expect(abs(Int(bytes[0]) - 191) <= 2, "White becomes 191 of 255")
        #expect(backdrop.colorSpace?.model == .monochrome)
    }

    @Test func aPNGRoundTrips() throws {
        let page = try #require(Self.image(width: 3, height: 2) { _, _ in (10, 20, 30) })
        let png = try #require(BrowserCaptureImaging.png(page))
        let decoded = try #require(BrowserCaptureImaging.cgImage(png: png))
        #expect(decoded.width == 3 && decoded.height == 2)
    }
}

// MARK: - BrowserCaptureCardViewTests

@MainActor struct BrowserCaptureCardViewTests {
    @Test func theCardDrawsTheGrayPageTheFramedPictureAndTheDarkMenu() throws {
        let picture = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { rect in
            NSColor.systemYellow.setFill()
            rect.fill()
            return true
        }
        let page = CGRect(x: 0, y: 0, width: 800, height: 500)
        let card = BrowserCaptureCardView(
            picture: picture,
            pictureFrame: CGRect(x: 100, y: 100, width: 200, height: 100),
            pageFrame: page,
            backdrop: nil,
            menu: BrowserCaptureCardMenu(),
        )
        card.frame = page
        card.layoutSubtreeIfNeeded()
        let bitmap = try #require(card.bitmapImageRepForCachingDisplay(in: card.bounds))
        card.cacheDisplay(in: card.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / card.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        // The menu panel's own color, beside the frame.
        let menu = try color(320, 330)
        #expect(abs(menu.redComponent * 255 - 18) < 3 && abs(menu.blueComponent * 255 - 44) < 3)
        // The frame's edge, then the picture inside it.
        let frame = try color(98, 150)
        #expect(abs(frame.blueComponent * 255 - 47) < 3)
        let inside = try color(200, 150)
        #expect(inside.redComponent > 0.8 && inside.blueComponent < 0.3)
    }

    @Test func escapeAndAClickOnTheGrayPageCloseIt() {
        let card = BrowserCaptureCardView(
            picture: NSImage(size: NSSize(width: 10, height: 10)),
            pictureFrame: CGRect(x: 100, y: 100, width: 10, height: 10),
            pageFrame: CGRect(x: 0, y: 0, width: 800, height: 500),
            backdrop: nil,
            menu: BrowserCaptureCardMenu(),
        )
        var dismissals = 0
        card.onDismiss = { dismissals += 1 }
        card.cancelOperation(nil)
        #expect(dismissals == 1)
    }
}
