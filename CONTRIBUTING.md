# Contributing to OpenArc

Thanks for helping. Bug reports, fixes, features, docs, forks and extensions are all welcome.

## Before you start

- Search the issues first. For a larger change, open an issue describing it so we can agree on the approach before you write it.
- Report security problems privately through GitHub's security advisories, not in a public issue.

## Setup

Follow [Building](README.md#building) in the README. The CEF build is a one-time cost. Later checkouts and worktrees reuse it with `./build.sh prepare-worktree`.

## Making a change

- Mac UI is AppKit and iOS UI is UIKit, both in Swift 6. Use Objective-C++ only where code talks to CEF, Chromium or low-level platform APIs.
- Keep state in models and controllers. Reuse `BrowserChromeColors`, `BrowserChromeLayout` and the shared controls in `Sources/Browser/NativeUI`. [docs/appkit-ui.md](docs/appkit-ui.md) describes the UI architecture.
- Write tests with Swift Testing, not XCTest. Move tests you touch to Swift Testing.
- Resize or thumbnail images with `BrowserImageThumbnailer`.
- Format changed Swift files with SwiftFormat and the repository's `.swiftformat`.
- `./build.sh build` must finish without warnings, and `./build.sh test` must pass.
- Changing `Chromium/chromium_src` means rebuilding CEF for both Debug and Release on the exported CEF version. Do not delete Chromium's `out/` directories.
- When you add an open-source dependency, add its license to `Sources/Browser/Resources/Credits.html` in the same change.
- [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md) hold the same rules for coding agents. Change both together.

## Commits and pull requests

- Name commits `<type>(<scope>): <message>` in lowercase. The type is `feature` for something users notice, `fix` for a bug, or `tech` for internal work. The scope is optional, as in `fix(sync): keep deleted tabs deleted`.
- Keep each pull request to one topic. Describe what changed, why, and how you checked it. Include screenshots for UI changes.

## License

OpenArc is licensed under the [Apache License 2.0](LICENSE). By contributing, you agree that your contribution is licensed under it too (section 5 of the license). You keep the copyright to your work, and no separate agreement is needed.

Forks are welcome, including private and commercial ones. Keep [LICENSE](LICENSE) and [NOTICE](NOTICE) in what you distribute.
