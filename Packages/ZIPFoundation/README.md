# ZIPFoundation

Vendored copy of [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) 0.9.20 (`22787ff`), MIT licensed.

Local changes:

- `Package.swift` targets macOS 14 and iOS 17 with Swift 6 language mode; the upstream manifests and the Linux `CZLib` shim are dropped.
- `maxUInt32` and `maxUInt16` in `Archive+ZIP64.swift` are `let` constants. Upstream tests mutate them, but Swift 6 rejects mutable globals.

`.swiftformat` excludes `Sources` so diffs against upstream stay readable.
