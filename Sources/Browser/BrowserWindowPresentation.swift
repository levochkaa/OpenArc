// BrowserWindowPresentation.swift

import Foundation

/// How OpenArc puts its windows up at launch. `--no-activate` is for automated
/// checks that run a copy of OpenArc while someone works on the Mac: the app
/// never activates itself, and its windows open behind other apps' windows
/// without taking the keyboard.
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
