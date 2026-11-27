// BrowserWindowPresentation.swift

import Foundation

/// How OpenArc puts its windows up at launch. `--no-activate` is for automated
/// checks that run a copy of OpenArc while someone works on the Mac: the app
/// never activates itself, and its windows open behind other apps' windows
/// without taking the keyboard. The check stands in for a person looking at
/// them, so the windows count as shown though other apps' windows cover them:
/// pages draw, take clicks and run what waits for a visible page on every
/// engine as they would in front.
enum BrowserWindowPresentation: Equatable {
    case frontAndActivate
    case behindOthers

    // MARK: Internal

    static let backgroundArgument = "--no-activate"

    static let current = forLaunch(arguments: ProcessInfo.processInfo.arguments)

    var activatesApplication: Bool {
        self == .frontAndActivate
    }

    static func forLaunch(arguments: [String]) -> Self {
        arguments.dropFirst().contains(backgroundArgument) ? .behindOthers : .frontAndActivate
    }
}
