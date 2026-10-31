# Mobile WebKit uploads

The mobile engine preserves WebKit's default file chooser. `BrowserWebKitEngine`
owns the `WKUIDelegate` and does not implement `runOpenPanel`. The installed
Xcode 26.6 `WKUIDelegate.h` explicitly documents Safari upload behavior when this
method is absent on iOS. Its macOS default is different and does not apply here.
See Apple's [open-panel delegate API](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runopenpanelwith:initiatedbyframe:completionhandler:)).

No replacement picker or production upload code was added. The public override
only provides multiple-selection and directory flags through
`WKOpenPanelParameters`; replacing the default with a generic document picker
would require a separate design for accept filters, media and capture behavior.

## Hosted verification

`BrowserWebKitUploadTests.swift` extends the serialized `BrowserMobileUITests`.
It mounts the real workspace, UIKit page and engine in the dedicated test-host
scene, with disposable SQLite/outbox, preferences and a nonpersistent data store.
The latter isolates the fixture; it does not implement product private browsing.

`UploadHTTPFixture` serves a real loopback HTML page containing single and multiple
`input type=file accept=text/plain` forms. Programmatic DOM activation opens a
WebKit-created `UIDocumentPickerViewController` in that window. The test checks
its multiple-selection flag and supplies disposable local URLs through its
existing public `UIDocumentPickerDelegate`. The delegate is never replaced.
Explicit UIKit dismissal only cleans up presentation; it is not a physical
Files action. WebKit may move the supplied files, so fixtures never use user data.

The tests check:

- Single and multiple FileList names and exact binary bytes, including UTF-8,
  CRLF, NUL and non-UTF-8 bytes; production navigation/UI delegates remain intact.
- A real form POST to localhost: exactly one request, exact multipart part count,
  names, filenames, MIME type and bytes, hidden token and source cookie.
- An injected Cancel callback leaves the input empty and emits no change; a new
  picker subsequently delivers a file through the same default path.
- Late selection after switching or closing the source tab, navigation to a new
  document, workspace deactivation/disconnection and shutdown does not populate
  the other document or change durable state beyond the explicit lifecycle action.
- Source tab/selection, URL, history, SQLite snapshot and sync outbox remain
  unchanged by selection. Intentional form submission is normal navigation.

The fixture starts attached and active before lifecycle transitions. Surviving
source documents must actually receive their late selection before the test checks
isolation. Invalidated requests have no public completion acknowledgement: their
new/other documents are observed repeatedly for one second. This is bounded
negative evidence, not a guarantee about arbitrary delayed providers. A late
result is injected only while the picker still has an installed delegate; a
cleared delegate is never resurrected. No private delegate is retained across a
transition. An old document may retain its own
selection when it remains valid; cancellation on every tab switch is not claimed.

The loopback server accepts bounded Content-Length requests, rejects chunked
framing explicitly, records raw bodies and parses exact CRLF multipart boundaries.
It is test infrastructure, not the sync backend. Teardown waits for actual SQLite
store release before deleting files; UIKit can retain a dismissed controller until
a later run-loop turn.

## Limits

This proves programmatic input activation → native picker presentation → injected
public result → WebKit FileList and real HTTP delivery. It does not prove physical
Files selection, external/security-scoped providers, Photos/camera, capture and
all accept filters, directory upload, drag-to-upload, OS scene delivery or actual
background suspension. Workspace lifecycle calls are controlled test actions.

