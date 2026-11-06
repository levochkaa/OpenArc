// BrowserInsetClampedTests.swift

import CoreGraphics
import Testing

// MARK: - BrowserInsetClampedTests

struct BrowserInsetClampedTests {
    @Test func aRectLargerThanItsInsetsMatchesInsetBy() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 40)
        #expect(rect.insetClamped(dx: 10, dy: 3) == rect.insetBy(dx: 10, dy: 3))
        #expect(rect.insetClamped(dx: -4, dy: 0) == rect.insetBy(dx: -4, dy: 0))
    }

    @Test func aRectSmallerThanItsInsetsStaysFiniteAtItsCenter() {
        #expect(CGRect.zero.insetBy(dx: 10, dy: 3).isNull, "insetBy gives the null rect")
        let clamped = CGRect.zero.insetClamped(dx: 10, dy: 3)
        #expect(clamped == CGRect(x: 0, y: 0, width: 0, height: 0))
        let guide = CGRect(x: 0, y: 50, width: 0, height: 0).insetClamped(dx: 8, dy: -8)
        #expect(guide == CGRect(x: 0, y: 42, width: 0, height: 16))
    }
}
