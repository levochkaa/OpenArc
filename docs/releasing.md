# Releasing

This covers the Mac app. The iOS app ships through TestFlight, see [ios-testflight.md](ios-testflight.md).

Releases are GitHub releases of `levochkaa/OpenArc`, served to the app by the server in `Backend` at `https://api.openarc.su`. The app reads its Sparkle feed from `https://api.openarc.su/appcast.xml`: the newest release that is not a pre-release, or with `?channel=beta`, which the Beta channel in Settings adds, the newest release of any kind. The server reads releases with `GITHUB_RELEASE_TOKEN` and proxies their downloads, so updates work while the repository is private. Publish with `--prerelease` to reach only the Beta channel.

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
2. Signs a copy with `script/sign_release_app.sh`: Developer ID, the hardened runtime, secure timestamps, `Support/OpenArc-Distribution.entitlements` and the helper entitlements. Apple does not offer Sign in with Apple to Developer ID apps, so these builds leave it out. The script embeds a Developer ID provisioning profile for the app's bundle ID (`OPENARC_PROVISIONING_PROFILE`, or the first one found in `~/Library/MobileDevice/Provisioning Profiles` or Xcode's profiles) and adds the `<team>.<bundle ID>.webauthn` keychain group, which Touch ID passkeys need. Without a profile the group is left out, since macOS stops an app whose keychain group no profile allows, and passkeys fall back to a phone or a security key. Xcode makes the profile when it exports an archive with the `developer-id` method and automatic signing.
3. Notarizes and staples that copy.
4. Zips it and generates the appcast, with the notes embedded and download links through `https://api.openarc.su/downloads/`, and deltas from the earlier archives in `.build/releases/sparkle-updates`. Keep that directory between releases so later updates stay small.
5. Uploads the archive, notes, appcast and deltas to the GitHub release.

`--no-notarize` skips signing and notarization, for local tests of the update flow.
