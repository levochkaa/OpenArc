# OpenArc

OpenArc is an open-source browser for macOS, iPhone and iPad. The Mac app runs Chromium through the Chromium Embedded Framework with a native AppKit interface; the iOS app uses WebKit and UIKit. It keeps the browser as a workspace: a sidebar of Spaces, pinned tabs and folders, a command bar, split view, and sync between devices.

OpenArc was created by [Lev Poznyakov](https://github.com/levochkaa). It is in development; 0.1.0 is the first release.

Website: [openarc.su](https://openarc.su)

## Repository

| Path | Contents |
| --- | --- |
| `Sources/Browser` | macOS app: Swift and AppKit, Objective-C++ where it talks to CEF |
| `Sources/Helper`, `Sources/Shared` | CEF helper processes and code shared with them |
| `Sources/BrowseriOS` | iPhone and iPad app |
| `Chromium/chromium_src` | Overrides applied to the Chromium and CEF checkout |
| `Backend` | Rust sync and update server ([README](Backend/README.md)) |
| `Website` | Landing page |
| `docs` | Design notes for individual features |

## Building

You need an Apple Silicon Mac with macOS 26, Xcode 27.1 at `/Applications/Xcode-27.1.0.app`, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (`brew install xcodegen swiftformat`).

The Mac app needs OpenArc's own CEF build, because full Chrome extension support depends on its Chromium overrides. Build it once. It checks out about 70 GB of Chromium and takes several hours:

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

`./build.sh --help` lists every action. Sync needs a server: `Backend/README.md` explains how to run one locally, and the Mac app connects to the one in `OPENARC_SYNC_BASE_URL`.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup, conventions and pull requests.

## License

OpenArc is licensed under the [Apache License 2.0](LICENSE). You may use, change and sell it, in open or closed-source products, as long as you keep the [LICENSE](LICENSE) and [NOTICE](NOTICE) files with your copies. NOTICE credits the project's creator.

OpenArc is an independent project. It is not affiliated with, endorsed by or sponsored by The Browser Company of New York, Inc. Arc is a trademark of its owner.
