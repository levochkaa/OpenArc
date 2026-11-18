## Code Preferences

- Target `Swift 6` using the Xcode 27.2 Swift 6.4 toolchain for Swift code and project settings unless a dependency or platform constraint in this repo explicitly requires otherwise.
- Write macOS UI in `AppKit` and iOS/iPadOS UI in `UIKit`, using Swift.
- Keep business state in models/controllers. Reuse `BrowserChromeColors`, `BrowserChromeLayout`, and the shared AppKit controls in `NativeUI`; see `docs/appkit-ui.md` for the UI architecture and verification workflow.
- For branded surfaces (the first-run welcome, the About window, the website), read `DESIGN.md` for direction, then the `antislop` skills as the filter, and finish with the antislop Delivery Gate.
- Use `Objective-C` / `Objective-C++` only where interaction with the browser engine, CEF, or low-level platform APIs requires it.
- When resizing or thumbnailing raster images, use `BrowserImageThumbnailer` instead of ad hoc `NSImage.draw`/`NSImage(data:)` resizing. Prefer its ImageIO/`CGImageSource` data or URL thumbnail path for encoded images.
- Always write tests with the new `Testing` framework, not `XCTest`, and migrate existing tests when modifying them.

## Build Verification

- Keep a separate Codex action named `Build` that runs `./build.sh build`.
- Keep a separate Codex action named `Test` that runs `./build.sh test`.
- Use Xcode 27.2 for build and test verification. The repo scripts export `DEVELOPER_DIR=/Applications/Xcode-27.2.0.app/Contents/Developer` by default. CEF and Chromium build with Xcode 26.6, since Chromium 148 supports only the macOS 26 SDK.
- Before running the `Build` action, run SwiftFormat on every `.swift` file changed in the current task, using the repository `.swiftformat` configuration.
- When changing CEF, Chromium, or `Chromium/chromium_src` override files, rebuild and export the `Release` CEF artifacts before running the `Build` action; the app build stages `Release` CEF even for a `Debug` app build. Rebuild `Debug` CEF only when asked.
- CEF/Chromium rebuilds must match the currently exported baseline from `ThirdParty/cef/export/include/cef_version.h` unless the user explicitly asks to move the CEF/Chromium base. Do not float `CEF_BRANCH` to a newer head for routine override rebuilds. Apply upstream CEF patches/project generation before applying `Chromium/chromium_src` overrides.
- Do not clobber Chromium `out/` build directories during CEF checkout/resume/package flows unless the user explicitly asks for a clean rebuild. Preserve existing CEF build cache by default; use `OPENARC_CEF_CLOBBER_OUT=1` only for intentional full rebuilds.
- Before finishing any task, run the `Build` action to verify the project compiles successfully in the console only. Do not launch `OpenArc` or `OpenArc Helper`, and do not check whether their processes started.
- If the `Build` action emits warnings, fix those warnings before treating the task as complete.
- After a successful `Build` action and before finishing any task, run the `Test` action to verify the test suite passes in the console. Run tests through `./build.sh test`, the same root script used by the Codex `Test` action, and not by calling `xcodebuild test` directly.
- `build.sh` builds in every checkout share resolved Swift package graphs and one compilation cache under `~/Library/Caches/OpenArcBuild`. Debug builds record the checkout path in debug info as `/^root` (Swift) or `/^src` (Objective-C++); Release builds keep real paths, so dSYMs and crash reports resolve. For Debug, in LLDB run `settings set target.source-map /^root <checkout> /^src <checkout>` before full-path breakpoints or source listing; `./build.sh debug` sets it.

## Commit Workflow

- Commit every task-owned change before finishing the task. Do not leave agent-created changes uncommitted unless the user explicitly asks not to commit.
- Keep commits focused and include only task-owned changes. Preserve pre-existing unrelated changes and never sweep them into a task commit.
- Do not push commits unless the user explicitly asks for a push.
- Name commits as `<type>(<scope>): <message>` when a short scope adds useful context, otherwise `<type>: <message>`.
- Allowed commit types are `feature` for product-visible additions or behavior expansions, `fix` for bugs and regressions, and `tech` for internal work, maintenance, tooling, cleanup, and chores. Use `tech`, not `chore`.
- Keep commit scopes small and lowercase. Keep commit messages lowercase by default, preserving exact capitalization only for identifiers, acronyms, product names, and user-facing strings that require it.
- Keep commit subjects concise and do not end them with a period.
- Add `Co-authored-by: Codex <noreply@openai.com>` to commits created with Codex. Other AI agents should use their own configured identity.

## Open Source Credits

- When adding an open-source project, add or update its entry in `Sources/Browser/Resources/Credits.html` in the same change.
- When updating package versions, refresh affected credit/license text from the upstream GitHub repository if it changed. For CEF/Chromium updates, use the credits from the updated CEF bundle.

## Instructions

- Read `LOCAL.md` from the main checkout's root before any task, when it exists (`$(git rev-parse --git-common-dir)/../LOCAL.md` in a worktree). It holds this machine's rules and notes kept out of the repository, and they apply on top of this file.
- Keep `AGENTS.md` under 32 KB: Codex does not read a larger one.
