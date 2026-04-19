## Code Preferences

- Prefer writing app UI and application code in `SwiftUI` whenever practical.
- If `SwiftUI` is not a good fit, prefer plain `Swift`.
- Use `Objective-C` / `Objective-C++` only where interaction with the browser engine, CEF, or low-level platform APIs requires it.

## Build Verification

- Keep a separate Codex action named `Build` that runs `./script/build_and_run.sh verify`.
- Before finishing any task, run the `Build` action to verify the project builds and both `TheBrowser` and `TheBrowser Helper` launch successfully.

## Doc Sync

- Any change to `AGENTS.md` must be mirrored in `CLAUDE.md` in the same change.
- Any change to `CLAUDE.md` must be mirrored in `AGENTS.md` in the same change.
