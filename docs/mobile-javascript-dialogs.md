# Mobile JavaScript dialogs

The UIKit browser implements WebKit alert, confirm and prompt through `BrowserWebKitEngine` → `BrowserMobileWorkspace` → `BrowserMobileJavaScriptDialogPresenter`. This extends I03.

## Reference and behavior

Apple's [alert contract](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runjavascriptalertpanelwithmessage:initiatedbyframe:completionhandler:)), [confirm contract](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runjavascriptconfirmpanelwithmessage:initiatedbyframe:completionhandler:)) and [prompt contract](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:runjavascripttextinputpanelwithprompt:defaulttext:initiatedbyframe:completionhandler:)), checked 2026-10-03, define the completion values and require identifying the initiating website. The native presentation uses [UIAlertController](https://developer.apple.com/documentation/uikit/uialertcontroller) without subclassing or private view access.

The title identifies the initiating frame's security origin, including a nondefault port. An opaque origin is labeled Unknown origin. Page-controlled messages remain separate from that title. Alert has OK; confirm has Cancel/OK; prompt also supplies an editable default value. Accepting an empty prompt returns an empty string. Cancel returns false for confirm and nil for prompt. Alert always completes its void callback.

## Ownership and cancellation

Each scene engine owns at most one pending UUID token, bound to a runtime tab and navigation generation. Dialog state never enters session files or sync. Admission requires the selected committed document and an active scene. A background, inactive, unknown or already busy request receives the neutral response without a waiting queue.

Navigation, tab changes/closure, Stop, process termination, shutdown and scene deactivation cancel a pending token. The engine removes ownership before callbacks; repeated answers and synchronous reentry cannot complete it twice. Replacing a document blocks old JavaScript resumed by cancellation until the next commit. Fragment navigation keeps the current document eligible using a separately tracked document URL, because WebKit frame/URL observations can already contain the target before policy callbacks. Embedded `about:srcdoc` frames are allowed; that URL remains unsupported as a top-level browser address. Failed provisional navigation/Stop leave the previously committed document eligible; web-content-process termination invalidates it.

The registry validates the current scene attachment before changing activity. Reconnection starts inactive. SceneDelegate samples that scene's current activation state after async connection and window binding, and deactivates on resign/background/disconnect. Discard deactivates before awaiting storage. Early restoration dialogs before UI activation receive neutral responses.

The presenter checks its own attached foreground window. It preserves an existing native modal such as a share sheet and cancels the page request. Cancellation dismisses only the owned alert. Normal user responses wait for native dismissal before resuming JavaScript, so consecutive page dialogs can present. An already-running dismissal uses its transition coordinator; all completion paths share a once-only guard. The model and engine reject late responses to canceled tokens.

## Verification boundary

Console tests run inside the dedicated BrowserMobileTestHost, not the TheBrowser product. Tests combine real WK JavaScript with the production model and actual UIKit alert presentation; response tests call the same presenter methods used by UIAlertAction handlers. Public dismissal APIs exercise either dismissal ordering. These are not physical taps on UIAlertAction buttons.

Engine tests distinguish actual script execution from direct lifecycle/completion boundary calls. Opaque iframe metadata comes from an actual WKScriptMessage; its modal response test invokes the delegate because sandbox modal admission belongs to WebKit. Scene tests call the production registry directly. Real OS background/Stage Manager behavior, native physical keyboard/accessibility action dispatch and app-owned scene delegate lifecycle remain unverified. Xcode 26.6 / iOS Simulator 26.5 passed 44 test declarations (54 runs) on both iPhone 17 Pro and iPad Air (5th generation), with zero failures or skips. System WebKit/RBS/haptics messages remain; the rapid frame/trait layout fixtures also emit unbalanced appearance-transition diagnostics. Those logs do not establish live resize/animation quality.

No persistence schema, desktop CEF behavior, backend protocol or permission-dialog policy changes in this slice. JavaScript modal spam controls beyond one outstanding request, site permissions, authentication, uploads/downloads and private browsing remain separate work.
