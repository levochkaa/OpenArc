# OpenArc

OpenArc is an open-source browser for macOS. It runs Chromium through the Chromium Embedded Framework with a native AppKit interface. It keeps the browser as a workspace: a sidebar of Spaces, pinned tabs and folders, a command bar and split view. It runs locally, with no account: everything stays on your device.

OpenArc was created by [Lev Poznyakov](https://github.com/levochkaa). It is in development; 0.1.0 is the first release.

## Repository

| Path | Contents |
| --- | --- |
| `Sources/Browser` | macOS app: Swift and AppKit, Objective-C++ where it talks to CEF |
| `Sources/Helper`, `Sources/Shared` | CEF helper processes and code shared with them |
| `Sources/BrowseriOS` | iPhone and iPad app, in development and not released |
| `Chromium/chromium_src` | Overrides applied to the Chromium and CEF checkout |
| `Backend` | Rust server for accounts and sync, unused while they are off ([README](Backend/README.md)) |
| `Website` | Privacy policy, terms and an undeployed landing page |
| `docs` | Design notes for individual features |

## Building

You need an Apple Silicon Mac with macOS 26, Xcode 27.2 at `/Applications/Xcode-27.2.0.app` for the apps, Xcode 26.6 at `/Applications/Xcode-26.6.0.app` for CEF, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (`brew install xcodegen swiftformat`).

The Mac app needs OpenArc's own CEF build, because full Chrome extension support depends on its Chromium overrides. Build it once. It checks out about 70 GB of Chromium and takes several hours. The script uses Xcode 26.6, because Chromium 148 does not build with the macOS 27 SDK:

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

Accounts and sync are off: `BrowserHostedService.isEnabled` in `Sources/Browser/BrowserSyncPlatformConfiguration.swift` turns them on. To try them, set it to `true` and set `OPENARC_SYNC_BASE_URL` in the environment to a server from `Backend/README.md` running locally.

[docs/releasing.md](docs/releasing.md) covers signing, notarization and updates.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, conventions and pull requests. [SECURITY.md](SECURITY.md) covers reporting vulnerabilities.

## License

OpenArc is released under the [MIT License](LICENSE). You may use, change and sell it, in open or closed-source products, as long as copies keep the license with its copyright line naming the project's creator.

OpenArc is an independent project. It is not affiliated with, endorsed by or sponsored by The Browser Company of New York, Inc. Arc is a trademark of its owner.
