import Testing

@Test func runtimeIdentitySanitizesWorktreeSuffix() {
    let suffix = BrowserRuntimeIdentity.suffix(arguments: [
        "OpenArc",
        "--runtime-suffix= worktree/feature : one ",
    ])

    #expect(suffix == "worktree-feature-one")
}

@Test func runtimeIdentityUsesFirstSuffixArgument() {
    let suffix = BrowserRuntimeIdentity.suffix(arguments: [
        "OpenArc",
        "--runtime-suffix=first",
        "--runtime-suffix=second",
    ])

    #expect(suffix == "first")
}

@Test func runtimeIdentityKeepsDefaultStoragePathsWithoutSuffix() {
    #expect(BrowserRuntimeIdentity.rootCacheDirectoryName(suffix: nil) == "CEF")
    #expect(BrowserRuntimeIdentity.sessionDirectoryName(suffix: nil) == "Session")
}

@Test func runtimeIdentityIsolatesCacheAndSessionStorageWithSuffix() {
    #expect(BrowserRuntimeIdentity.rootCacheDirectoryName(suffix: "worktree-123") == "CEF-worktree-123")
    #expect(BrowserRuntimeIdentity.sessionDirectoryName(suffix: "worktree-123") == "Session-worktree-123")
}
