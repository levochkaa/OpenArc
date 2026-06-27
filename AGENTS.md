## Code Preferences

- Target `Swift 6` using the Xcode 26.5 Swift 6.3 toolchain for Swift code and project settings unless a dependency or platform constraint in this repo explicitly requires otherwise.
- Prefer writing app UI and application code in `SwiftUI` whenever practical.
- If `SwiftUI` is not a good fit, prefer plain `Swift`.
- Use `Objective-C` / `Objective-C++` only where interaction with the browser engine, CEF, or low-level platform APIs requires it.
- When resizing or thumbnailing raster images, use `BrowserImageThumbnailer` instead of ad hoc `NSImage.draw`/`NSImage(data:)` resizing. Prefer its ImageIO/`CGImageSource` data or URL thumbnail path for encoded images.
- Always write tests with the new `Testing` framework, not `XCTest`, and migrate existing tests when modifying them.

## Build Verification

- Keep a separate Codex action named `Build` that runs `./script/build.sh`.
- Keep a separate Codex action named `Test` that runs `./script/test.sh`.
- Use Xcode 26.5 for build and test verification. The repo scripts export `DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer` by default.
- Before running the `Build` action, run SwiftFormat on every `.swift` file changed in the current task, using the repository `.swiftformat` configuration.
- When changing CEF, Chromium, or `Chromium/chromium_src` override files, rebuild and export both `Debug` and `Release` CEF artifacts before running the `Build` action. The app build may stage `Release` CEF even for a `Debug` app build.
- CEF/Chromium rebuilds must match the currently exported baseline from `ThirdParty/cef/export/include/cef_version.h` unless the user explicitly asks to move the CEF/Chromium base. Do not float `CEF_BRANCH` to a newer head for routine override rebuilds. Apply upstream CEF patches/project generation before applying `Chromium/chromium_src` overrides.
- Do not clobber Chromium `out/` build directories during CEF checkout/resume/package flows unless the user explicitly asks for a clean rebuild. Preserve existing CEF build cache by default; use `THEBROWSER_CEF_CLOBBER_OUT=1` only for intentional full rebuilds.
- Before finishing any task, run the `Build` action to verify the project compiles successfully in the console only. Do not launch `TheBrowser` or `TheBrowser Helper`, and do not check whether their processes started.
- If the `Build` action emits warnings, fix those warnings before treating the task as complete.
- After a successful `Build` action and before finishing any task, run the `Test` action to verify the test suite passes in the console. Run tests through `./script/test.sh`, the same script used by the Codex `Test` action, and not by calling `xcodebuild test` directly.

## Open Source Credits

- When adding an open-source project, add or update its entry in `Sources/Browser/Resources/Credits.html` in the same change.
- When updating package versions, refresh affected credit/license text from the upstream GitHub repository if it changed. For CEF/Chromium updates, use the credits from the updated CEF bundle.

## Doc Sync

- Any change to `AGENTS.md` must be mirrored in `CLAUDE.md` in the same change.
- Any change to `CLAUDE.md` must be mirrored in `AGENTS.md` in the same change.
