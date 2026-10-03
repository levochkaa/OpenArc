# Mobile HTTP Basic authentication

`BrowserWebKitEngine` implements `WKNavigationDelegate`'s authentication
challenge handler for HTTP Basic. Without it, WebKit rejects the protection
space and renders the server's 401 document: the installed Xcode 26.6
`WKNavigationDelegate.h` (lines 150–160) documents
`NSURLSessionAuthChallengeRejectProtectionSpace` as the default. A baseline run
before this change confirmed it: no prompt, no credentials, title
"Authentication required". See Apple's
[authentication challenge API](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:didreceive:completionhandler:)).

## Behavior

- Only non-proxy `NSURLAuthenticationMethodHTTPBasic` challenges for http/https
  are prompted. TLS server trust, client certificates, Digest/NTLM and proxies
  keep WebKit's default. There is no trust bypass.
- A prompt is admitted only for the selected, mounted runtime in an active,
  visible, foreground window, with no pending JavaScript dialog or other
  challenge. Unadmitted challenges keep the default rejection.
- The alert title is the protection-space origin (`http://host:port`). The
  server-supplied realm is shown as plain bounded text in the message. A retry
  after wrong credentials shows a new prompt with an explicit failure line;
  credentials are never replayed automatically.
- Sign In sends `URLCredential(..., persistence: .none)`. Credentials pass only
  from the alert's text fields to WebKit's completion handler. They are not in
  events, logs, SQLite, the sync outbox, AccountStore or Keychain. The fields are
  cleared when the alert finishes.
- Cancel rejects the protection space, as Chromium does: WebKit renders the
  server's 401 document at the challenged address and Reload prompts again.
- Find in Page, Downloads and JavaScript dialogs are refused while a prompt is
  pending.

## Ownership and lifecycle

The engine owns a single pending token: UUID, runtime ID, load generation,
web-view identity, origin, realm and failure count. The token is removed before
its completion runs and settles exactly once.

| Transition | Result |
| --- | --- |
| Sign In, still valid after dismissal | `.useCredential` |
| Cancel; tab switch; window deactivation or detach | `.rejectProtectionSpace` (401 page, Reload retries) |
| Navigation, Stop, close, shutdown, load failure, process termination, download conversion | `.cancelAuthenticationChallenge` |
| Stale token, changed generation or web view | `.cancelAuthenticationChallenge`; late credentials are dropped |

`BrowserMobileWorkspace` mirrors the transient request for its window and
revalidates edit access, active presentation and the selected runtime before
forwarding a response. `BrowserMobileHTTPAuthenticationPresenter`, owned by
`BrowserMobileViewController` next to the JavaScript dialog presenter, presents
one `UIAlertController` with username, secure password, Cancel and Sign In. It
responds only after dismissal finishes and only if the same window is still
active and uncovered; otherwise it answers Cancel.

## Verification

`BrowserWebKitAuthenticationTests.swift` runs in the serialized
`BrowserMobileUITests` against `BasicAuthHTTPFixture`, a loopback server that
returns a real 401 Basic challenge and counts missing, invalid and valid
`Authorization` headers. Tests mount the real workspace, UIKit controller and
WebKit engine with disposable SQLite, outbox and nonpersistent website data.

- Wrong password, then a new retry prompt with `previousFailureCount > 0`, then
  the correct password loads the protected page with exactly one valid request.
  A stale token cannot answer the retry. The password field is secure. SQLite
  and the outbox do not change while typing, and the persisted snapshot holds
  neither the username nor the password.
- Cancel sends no credentials, shows the 401 page at `/protected`, and Reload
  prompts again with a new token.
- Navigate, switch, close, inactive, disconnect, stop and shutdown each dismiss
  the alert, clear its fields, and drop late credentials from both the presenter
  and the workspace. Deactivation leaves the 401 page at the protected address.
- Two windows keep separate prompts; deactivating one does not affect the other.

## Limits

- WebKit supplies no `WKNavigation` or `WKFrameInfo` with the challenge, so
  there is no frame attribution. The generation guard protects admitted tokens;
  it cannot prove whether a challenge first arriving after a new navigation
  began belongs to the old load.
- Production scenes share the `.default()` website data store. Sync sign-out
  does not clear WebKit's per-session site authentication.
- No password autofill, saved site credentials, or Keychain integration.
- Tests call presenter and workspace methods directly; physical typing and real
  OS scene deactivation were not exercised. The site authentication UI was not
  observed.
