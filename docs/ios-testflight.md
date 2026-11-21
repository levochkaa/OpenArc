# iOS TestFlight

The iOS and iPadOS app ships through TestFlight. The Mac app keeps its own channel, see [releasing.md](releasing.md).

## One-time setup

- An app record in App Store Connect for the app's bundle ID, `com.levochkaa.OpenArc`. The public API cannot create one: App Store Connect > Apps > + > New App, platform iOS, name `OpenArc`, primary language English (U.S.), bundle ID `com.levochkaa.OpenArc`, SKU `OpenArc`.
- The bundle ID on the developer portal with the Sign in with Apple capability, which `Support/OpenArciOS.entitlements` declares.
- An Apple Distribution certificate with its private key in the login keychain. Xcode's automatic signing makes the App Store provisioning profile.
- The Paid Apps or Free Apps agreement accepted in App Store Connect > Business. Uploads fail without it.
- An App Store Connect API key with the Admin or App Manager role, exported in the shell:

  ```bash
  export OPENARC_ASC_KEY_ID=...
  export OPENARC_ASC_ISSUER_ID=...
  export OPENARC_ASC_KEY_PATH=/path/to/AuthKey_KEYID.p8
  ```

## Uploading a build

```bash
./script/ios_testflight.sh
```

The script:

1. Generates the project and reads the bundle ID and `MARKETING_VERSION` from the `OpenArciOS` Release settings. The signing team is the one that owns the bundle ID, or `DEVELOPMENT_TEAM`.
2. Takes the next build number from App Store Connect: one above the highest iOS build of any version, and at least `CURRENT_PROJECT_VERSION` from `project.yml`. It passes the number to `xcodebuild` and leaves `project.yml` unchanged, since the Mac app's Sparkle updates count their own build numbers. `--build-number N` sets it by hand.
3. Archives `OpenArciOS` in Release for `generic/platform=iOS` with automatic signing. `-allowProvisioningUpdates` and the API key let Xcode create or refresh the profile.
4. Exports with the `app-store-connect` method and the `upload` destination, which sends the build to App Store Connect with the same key and uploads its symbols.
5. Creates the internal TestFlight group `Internal` if it is missing and adds the team's Account Holder and Admins to it. `--group`, `--tester EMAIL` and `--no-admins` change that.
6. Waits for App Store Connect to process the build, then adds it to the group, which makes it available in the TestFlight app.

Logs, the archive and the export options land in `.build/ios-testflight/<version>-<build>/`. `--archive-only` stops after exporting an `.ipa` there; `--no-wait` stops after the upload.

`script/asc_api.py` is the App Store Connect API client the script uses. It signs its ES256 token with `openssl` and reads the key only from the environment. It also answers ad-hoc questions, for example `python3 -I script/asc_api.py build-status com.levochkaa.OpenArc 0.3.1 5`.

## Review answers in the build

`Support/OpenArciOS-Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false`: the app uses only the encryption built into the system (HTTPS, the keychain), so builds need no export compliance answer. Its purpose strings cover what websites can request through WebKit: camera, microphone, location while in use, and saving images to Photos. `Sources/BrowseriOS/Resources/PrivacyInfo.xcprivacy` declares the required-reason APIs the app calls: `UserDefaults` and file attributes inside its container.

## Testers

Internal testers are App Store Connect users of the team; each one gets an email invitation and installs builds from the TestFlight app. External testers need a group of their own, the Test Information page filled in (description, feedback email, contact and sign-in details) and Beta App Review of the first build of each version.

`python3 -I script/asc_api.py external-build com.levochkaa.OpenArc Public BUILD_ID --whats-new "..."` gives a build to external testers. It fills the Test Information page and copies the Beta App Review contact and notes from the App Store review details when they are empty, creates the external group with a public link if it is missing, adds the build and submits it for Beta App Review, then prints the public link. The build ID is the one `build-status` prints. Testers can install once Beta App Review approves the build.

## App Store listing

The listing is in App Store Connect, not in the repository: English (U.S.) only, since the app is English only. Primary category Productivity, secondary Utilities. The age rating answers "unrestricted web access", which every browser must. China mainland is left out of availability, since it needs an ICP filing.

Screenshots come from the Debug simulator build on an iPhone 17 Pro Max (6.9-inch, 1320×2868) and an iPad Pro 13-inch (2064×2752), with the status bar set by `xcrun simctl status_bar <device> override --time 9:41 ...` and demo Spaces of public sites. Each sits on the blue field from `DESIGN.md` under a one-line caption. App Store Connect wants PNG or JPEG without an alpha channel.

The App Privacy answers cannot be set through the API. Without an account the app collects nothing. With a sync account it collects, linked to the user and only for app functionality: email address, user ID, browsing history (the addresses and titles of synced tabs), and other user content (Space and folder names).
