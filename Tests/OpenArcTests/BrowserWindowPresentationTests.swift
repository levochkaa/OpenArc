// BrowserWindowPresentationTests.swift

import Testing

@Test func windowPresentationActivatesOnNormalLaunch() {
    let presentation = BrowserWindowPresentation.forLaunch(arguments: [
        "OpenArc",
        "--runtime-suffix=work",
    ])

    #expect(presentation == .frontAndActivate)
    #expect(presentation.activatesApplication)
}

@Test func windowPresentationStaysBehindWithNoActivate() {
    let presentation = BrowserWindowPresentation.forLaunch(arguments: [
        "OpenArc",
        "--runtime-suffix=smoke",
        "--no-activate",
        "--agent-socket=/tmp/smoke.sock",
    ])

    #expect(presentation == .behindOthers)
    #expect(!presentation.activatesApplication)
}

@Test func windowPresentationIgnoresExecutablePathAndLookalikes() {
    #expect(BrowserWindowPresentation.forLaunch(arguments: ["--no-activate"]) == .frontAndActivate)
    #expect(BrowserWindowPresentation.forLaunch(arguments: ["OpenArc", "--no-activate=1"]) == .frontAndActivate)
}
