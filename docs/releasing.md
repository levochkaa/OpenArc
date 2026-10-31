# Releasing

Releases are GitHub releases of `levochkaa/OpenArc`, and no OpenArc server is involved. The app reads its Sparkle feed from `https://github.com/levochkaa/OpenArc/releases/latest/download/appcast.xml`, the `appcast.xml` of the newest release that is not a pre-release. Updates therefore need a public repository. Pre-releases reach nobody through the updater: the Beta channel needs the server in `Backend` and stays hidden while `BrowserHostedService.isEnabled` is off.

Sparkle compares build numbers, so every release needs a higher `CURRENT_PROJECT_VERSION` in `project.yml` than any earlier release.

## One-time setup

- A Developer ID Application certificate in the login keychain. Only the team's Account Holder can create one.
- Notarization credentials from an App Store Connect Team key with the Developer role. Store them with `xcrun notarytool store-credentials openarc-notary --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER`.
- The Sparkle EdDSA private key in the keychain under the account `OpenArc`. Its public key is `OPENARC_SPARKLE_PUBLIC_KEY` in `project.yml`.
- `gh`, signed in with access to the repository.
- A Release CEF export. Build it with Xcode 26.6, because Chromium 148 supports only the macOS 26 SDKs: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer ./script/chromium_source.sh build Release`.

## Publishing

```bash
./script/create_sparkle_release.sh --repo levochkaa/OpenArc --notes notes.md
```

The script:

1. Builds Release.
2. Signs a copy with `script/sign_release_app.sh`: Developer ID, the hardened runtime, secure timestamps, `Support/OpenArc-Distribution.entitlements` and the helper entitlements. Apple does not offer Sign in with Apple to Developer ID apps, so these builds leave it out and need no provisioning profile.
3. Notarizes and staples that copy.
4. Zips it and generates the appcast, with the notes embedded and download links into this release, and deltas from the earlier archives in `.build/releases/sparkle-updates`. Keep that directory between releases so later updates stay small.
5. Uploads the archive, notes, appcast and deltas to the GitHub release.

`--no-notarize` skips signing and notarization, for local tests of the update flow.
