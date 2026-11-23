// OpenArcTestsSetup.swift

import AppKit
import Testing

// MARK: - OpenArcTestEnvironment

/// What the test run may do with the Mac it runs on.
enum OpenArcTestEnvironment {
    /// `./build.sh test --all`: the test process may become the active app, so tests that need a key window or an
    /// active app run. A plain `./build.sh test` leaves the keyboard and the front app to the person at the Mac.
    static let allowsFocus = ProcessInfo.processInfo.environment["OPENARC_TESTS_FOCUS"] == "1"

    static let focusTrait = ConditionTrait.enabled(
        if: allowsFocus,
        "needs the active app: run ./build.sh test --all",
    )
}

// MARK: - OpenArcTestsSetup

/// XCTest makes the bundle's principal class before any test runs. `xctest` starts as a process that can never become
/// the active app, and a plain run keeps it so even if a test host or code under test would change that; `--all`
/// lets it become active for the tests that need it.
@objc(OpenArcTestsSetup) final class OpenArcTestsSetup: NSObject {
    override init() {
        super.init()
        let policy: NSApplication.ActivationPolicy = OpenArcTestEnvironment.allowsFocus ? .regular : .prohibited
        let apply = { @MainActor in _ = NSApplication.shared.setActivationPolicy(policy) }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.sync(execute: apply)
        }
    }
}

/// A plain test run never becomes the active app; `--all` may.
@MainActor @Test func testProcessBecomesActiveOnlyWithAll() {
    let expected: NSApplication.ActivationPolicy = OpenArcTestEnvironment.allowsFocus ? .regular : .prohibited
    #expect(NSApplication.shared.activationPolicy() == expected)
}
