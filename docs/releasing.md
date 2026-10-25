# Releasing

Releases are GitHub releases of `levochkaa/OpenArc`. The sync server in `Backend` serves their Sparkle appcasts and downloads from `https://api.openarc.su`. Settings → General → Update Channel picks one of two channels:

| Channel | Feed | Serves |
| --- | --- | --- |
| Stable | `/appcast.xml` | The newest release that is not a pre-release |
| Beta | `/appcast.xml?channel=beta` | The newest release of either kind |

Sparkle compares build numbers, so every release needs a higher `CURRENT_PROJECT_VERSION` in `project.yml` than any earlier release in either channel.

## One-time setup

- A Developer ID Application certificate in the login keychain. Only the team's Account Holder can create one.
- A Developer ID provisioning profile for `com.levochkaa.OpenArc`. macOS honors Sign in with Apple in a Developer ID build only with this profile. Point `OPENARC_PROVISIONING_PROFILE` at it.
- Notarization credentials from an App Store Connect Team key with the Developer role. Store them with `xcrun notarytool store-credentials openarc-notary --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER`.
- The Sparkle EdDSA private key in the keychain under the account `OpenArc`. Its public key is `OPENARC_SPARKLE_PUBLIC_KEY` in `project.yml`.
- `gh`, signed in with access to the repository.
- A Release CEF export. Build it with Xcode 26.6, because Chromium 148 supports only the macOS 26 SDKs: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer ./script/chromium_source.sh build Release`.

## Publishing

```bash
export OPENARC_PROVISIONING_PROFILE=/path/to/OpenArc_Developer_ID.provisionprofile
./script/create_sparkle_release.sh --repo levochkaa/OpenArc --notes notes.md               # Stable
./script/create_sparkle_release.sh --repo levochkaa/OpenArc --notes notes.md --prerelease  # Beta
```

The script:

1. Builds Release.
2. Signs a copy with `script/sign_release_app.sh`: Developer ID, the hardened runtime, secure timestamps, and the helper entitlements in `Support`.
3. Notarizes and staples that copy.
4. Zips it and generates the appcast, with deltas from the earlier archives in `.build/releases/sparkle-updates`. Keep that directory between releases so later updates stay small.
5. Uploads the archive, notes, appcast and deltas to the GitHub release.

`--no-notarize` skips signing and notarization, for local tests of the update flow.
