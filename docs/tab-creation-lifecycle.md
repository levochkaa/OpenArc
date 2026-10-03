# Tab creation and retry

Logical tab allocation and browser creation are separate events. A tab keeps its stable sync ID, runtime ID, position, metadata and selection if its browser cannot be created.

## Contract

The app-owned CEF bridge emits the existing logical-created notification, then a creation state. The Swift driver delivers tab events on the main queue in FIFO order, after the synchronous allocation call returns.

- `creating`: the bridge has requested a browser. This is independent of page loading.
- `ready`: the real `OnAfterCreated` callback attached a browser to the existing record. It does not mean the document finished loading.
- `failed`: `CefBrowserHost::CreateBrowser` synchronously returned false. No timeout converts an accepted, slow request into a failure.

Only a failed record admits Retry. A retry retains the runtime ID and uses a new CEF client with the tab's current URL. The admission Boolean reports whether an attempt started, even if CEF refuses again. Creating, ready, closed and unknown records reject retries. The bridge closes a browser delivered for a canceled record instead of recreating the logical tab.

The pinned CEF checkout and export both identify `0d9d52a65c74c729e568ebf8506141a1e754eaeb`. In `ThirdParty/cef/source/chromium/src/cef/libcef/browser/browser_host_create.cc`, all synchronous false returns precede helper allocation and asynchronous scheduling (lines 54–100). This is the basis for reusing the ID after refusal. The accepted request's helper ignores a later `CreateBrowserSync` null result (lines 30–32 and 111–131); that failure is not covered by the immediate-refusal contract.

The model ignores outcomes for removed or dormant tabs and duplicate or obsolete transitions. After termination, late readiness force-closes the engine record before the driver can acknowledge and load it. Creation state is runtime-only: state changes and retries do not write a session snapshot, create a sync mutation or alter Undo references. Restart restores the durable logical tab and starts a fresh browser attempt.

## Native behavior

The content view distinguishes initial browser startup, tab creation and a creation error. Failed creation offers Retry, including in web-app windows. Reload and Force Reload retry a failed selected tab. The content host is hidden while waiting or failed so a previous page is not shown as the new tab. All controls use the existing AppKit components and localized strings.

## Scope and verification

Swift Testing covers model transitions, repeated refusal, retry admission, identity/order/selection preservation, ignored removed identities, remote projection and durable SQLite state. Offscreen AppKit tests cover the content states and its production Retry binding to the real model. Both application roots use that binding; Build checks those call sites and the Objective-C++/Swift delegate integration. The isolated test target does not compile the full application roots or Sparkle.

These checks do not launch CEF or prove real page loading, live input or a real engine refusal. An accepted request that never produces a callback remains creating; renderer-process failure is a separate lifecycle. The subsequent [pending-navigation repair](pending-navigation.md) retains newer local/remote addresses before attachment and starts loading only after the model receives ready. No vendor CEF/Chromium changes or baseline update are part of these slices.

Live focus after the loading overlay disappears also needs runtime verification. The pinned Chromium macOS responder implementation does not reject a hidden ancestor explicitly, so code review alone did not establish a focus regression. No speculative focus retry was added that could steal focus from address input. Extension popup/panel delegates retain their existing presentation; this slice adds recovery controls only to normal browser and web-app content.
