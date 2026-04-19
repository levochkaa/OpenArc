## Code Preferences

- Target `Swift 5.10` for Swift code and project settings unless a dependency or platform constraint in this repo explicitly requires otherwise.
- Prefer writing app UI and application code in `SwiftUI` whenever practical.
- If `SwiftUI` is not a good fit, prefer plain `Swift`.
- Use `Objective-C` / `Objective-C++` only where interaction with the browser engine, CEF, or low-level platform APIs requires it.
- Always write tests with the new `Testing` framework, not `XCTest`, and migrate existing tests when modifying them.

## Build Verification

- Keep a separate Codex action named `Build` that runs `./script/build_and_run.sh verify`.
- Keep a separate Codex action named `Test` that runs `./script/test.sh`.
- Before finishing any task, run the `Build` action to verify the project compiles successfully in the console only. Do not launch `TheBrowser` or `TheBrowser Helper`, and do not check whether their processes started.
- After a successful `Build` action and before finishing any task, run the `Test` action to verify the test suite passes in the console. Run tests through `./script/test.sh`, the same script used by the Codex `Test` action, and not by calling `xcodebuild test` directly.

## Doc Sync

- Any change to `AGENTS.md` must be mirrored in `CLAUDE.md` in the same change.
- Any change to `CLAUDE.md` must be mirrored in `AGENTS.md` in the same change.
