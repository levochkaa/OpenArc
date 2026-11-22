# OpenArc

OpenArc is an open-source macOS browser. It runs Chromium through the Chromium Embedded Framework with a native AppKit interface. The layout centers on a workspace: a sidebar of Spaces, pinned tabs, and folders, plus a command bar and split view. Accounts are optional. With an account, Spaces, tabs, and Boosts sync across Macs and the iPhone app; without one, all data stays on your device. Settings ▸ Advanced ▸ Engine can also run pages on Chrome's own framework or WebKit.

[Lev Poznyakov](https://github.com/levochkaa) created OpenArc. Releases are on the [releases page](https://github.com/levochkaa/OpenArc/releases), and the app updates itself. The iPhone app is in public beta on [TestFlight](https://testflight.apple.com/join/cDCTGXg8).

## Repository

| Path | Contents |
| --- | --- |
| `Sources/Browser` | macOS app: Swift and AppKit, Objective-C++ where it talks to CEF |
| `Sources/Helper`, `Sources/Shared` | CEF helper processes and code shared with them |
| `Sources/BrowseriOS` | iPhone and iPad app; iPhone app is in beta on TestFlight, iPad app is unreleased |
| `Chromium/chromium_src` | Overrides applied to the Chromium and CEF checkout |
| `Backend` | Rust server for accounts, sync, and shared links at `api.openarc.su` ([README](Backend/README.md)) |
| `Website` | The openarc.su site: landing page, privacy policy, terms, and support |
| `docs` | Design notes for individual features |

## Building

You need an Apple Silicon Mac with macOS 26, Xcode 27.2 at `/Applications/Xcode-27.2.0.app` for the apps, Xcode 26.6 at `/Applications/Xcode-26.6.0.app` for CEF, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (`brew install xcodegen swiftformat`).

The Mac app needs OpenArc's own CEF build because full Chrome extension support depends on its Chromium overrides. Build it once. It checks out about 70 GB of Chromium and takes several hours on either a Linux build host or a Mac. Both use the macOS 26.5 SDK from Xcode 26.6, which Chromium 158 expects. [docs/cef-build.md](docs/cef-build.md) covers the Linux host; on a Mac:

```bash
./script/chromium_source.sh package Debug Release
```

Then:

```bash
./build.sh build       # build the Mac app
./build.sh test        # run its tests
./build.sh run         # build and launch it
./build.sh ios-build   # build the iOS app for the simulator
```

`build.sh` signs with the project's Apple team by default. Without access to that team, sign with your own or turn signing off:

```bash
DEVELOPMENT_TEAM=YOURTEAMID ./build.sh build
./build.sh build --no-code-signing
./build.sh test --no-code-signing
```

`./build.sh --help` lists every action.

Accounts and sync use `https://api.openarc.su`. Set `OPENARC_SYNC_BASE_URL` in the environment to use another server, such as a local instance from `Backend/README.md`. `BrowserHostedService.isEnabled` in `Sources/Browser/BrowserSyncPlatformConfiguration.swift` disables accounts, sync, and the Beta update channel for a local-only build.

[docs/releasing.md](docs/releasing.md) covers signing, notarization and updates. [docs/ios-testflight.md](docs/ios-testflight.md) covers iOS builds for TestFlight.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, conventions and pull requests. [SECURITY.md](SECURITY.md) covers reporting vulnerabilities.

## License

OpenArc is released under the [MIT License](LICENSE). You may use, change and sell it, in open or closed-source products, as long as copies keep the license with its copyright line naming the project's creator.

OpenArc is an independent project. It is not affiliated with, endorsed by or sponsored by The Browser Company of New York, Inc. Arc is a trademark of its owner.
