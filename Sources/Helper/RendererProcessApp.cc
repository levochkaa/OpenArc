#include <CoreFoundation/CoreFoundation.h>
#include <unistd.h>

#include <map>
#include <string>

#include "Shared/AppFactory.h"
#include "Shared/BrowserMediaMessages.h"
#include "Shared/BrowserProtectedMedia.h"
#include "Shared/BrowserSchemes.h"
#include "Helper/FairPlayBridgeScript.h"
#include "Helper/ProtectedVideoBridgeScript.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"

namespace shared {

namespace {

// Watches the frame's media elements and Media Session for the sidebar's
// audio indicator and mini player. It runs in
// the page's main world before the page's scripts: detached `Audio` objects
// and Media Session handlers live there. Its two hooks are proxies of the
// native methods, so they keep their native names and source text. It
// reports only changes, and polls once a second while something plays,
// since decoded audio and metadata change without events. It returns the
// control function the browser's commands call.
constexpr char kMediaObserverScript[] = R"JS(
(function (report) {
  'use strict';
  const NativeProxy = Proxy;
  const apply = Reflect.apply;
  const stringify = JSON.stringify;
  const setTimer = window.setTimeout.bind(window);
  const clearTimer = window.clearTimeout.bind(window);
  const microtask = window.queueMicrotask.bind(window);
  const MediaElement = HTMLMediaElement;
  const VideoElement = HTMLVideoElement;
  const proto = MediaElement.prototype;
  const nativePlay = proto.play;
  const nativePause = proto.pause;
  const eventTypes = ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'];
  const tracked = new Set();
  const listening = new WeakSet();
  const actions = new Map();
  let pausedByBrowser = new Set();
  let lastPaused = null;
  let last = stringify([false, false, false, false, false, false, '']);
  let timer = 0;
  let queued = false;
  const sessionProto = typeof MediaSession === 'function' ? MediaSession.prototype : null;
  if (sessionProto && typeof sessionProto.setActionHandler === 'function') {
    sessionProto.setActionHandler = new NativeProxy(sessionProto.setActionHandler, {
      apply(target, session, args) {
        const result = apply(target, session, args);
        if (args[1]) {
          actions.set(args[0], args[1]);
        } else {
          actions.delete(args[0]);
        }
        schedule();
        return result;
      },
    });
  }
  const hasAudio = (media) => media.webkitAudioDecodedByteCount > 0 ||
    (media.srcObject && typeof media.srcObject.getAudioTracks === 'function' &&
      media.srcObject.getAudioTracks().length > 0);
  const resumable = (media) => media.paused && !media.ended && media.currentTime > 0 &&
    (media.isConnected || pausedByBrowser.has(media) || media === lastPaused);
  function evaluate() {
    queued = false;
    let playing = false;
    let paused = false;
    let audible = false;
    let video = false;
    for (const media of tracked) {
      if (!media.paused && !media.ended) {
        playing = true;
        audible = audible || (!media.muted && media.volume > 0 && hasAudio(media));
        video = video || (media instanceof VideoElement && media.videoWidth > 0);
      } else if (resumable(media)) {
        paused = true;
        video = video || (media instanceof VideoElement && media.videoWidth > 0);
      } else if (!media.isConnected) {
        tracked.delete(media);
      }
    }
    // Pages that make many short sounds keep only their newest elements.
    for (const media of tracked) {
      if (tracked.size <= 64) {
        break;
      }
      if (media.paused && media !== lastPaused && !pausedByBrowser.has(media)) {
        tracked.delete(media);
      }
    }
    const metadata = navigator.mediaSession && navigator.mediaSession.metadata;
    const state = [audible, playing, paused && !playing, video, actions.has('previoustrack'),
      actions.has('nexttrack'), !!document.pictureInPictureElement,
      metadata && metadata.title ? String(metadata.title) : ''];
    const key = stringify(state);
    if (key !== last) {
      last = key;
      apply(report, null, state);
    }
    clearTimer(timer);
    timer = playing ? setTimer(evaluate, 1000) : 0;
  }
  function schedule() {
    if (!queued) {
      queued = true;
      microtask(evaluate);
    }
  }
  function changed(event) {
    const media = event.target;
    if (event.type === 'play' || event.type === 'playing') {
      pausedByBrowser.delete(media);
    } else if (event.type === 'pause' && !media.ended) {
      lastPaused = media;
    } else if (event.type === 'ended' || event.type === 'emptied') {
      pausedByBrowser.delete(media);
      if (lastPaused === media) {
        lastPaused = null;
      }
    }
    schedule();
  }
  function track(media) {
    if (!(media instanceof MediaElement)) {
      return;
    }
    tracked.add(media);
    if (!listening.has(media)) {
      listening.add(media);
      for (const type of eventTypes) {
        media.addEventListener(type, changed);
      }
    }
    schedule();
  }
  proto.play = new NativeProxy(nativePlay, {
    apply(target, media, args) {
      track(media);
      return apply(target, media, args);
    },
  });
  window.addEventListener('play', (event) => track(event.target), true);
  window.addEventListener('playing', (event) => track(event.target), true);
  window.addEventListener('enterpictureinpicture', (event) => track(event.target), true);
  window.addEventListener('leavepictureinpicture', (event) => track(event.target), true);
  return function control(action) {
    const handler = actions.get(action);
    if (action === 'pause') {
      pausedByBrowser = new Set();
      for (const media of tracked) {
        if (!media.paused) {
          pausedByBrowser.add(media);
        }
      }
      if (handler) {
        handler({ action });
      } else {
        for (const media of pausedByBrowser) {
          apply(nativePause, media, []);
        }
      }
    } else if (action === 'play') {
      if (handler) {
        handler({ action });
      } else {
        const targets = pausedByBrowser.size > 0 ? Array.from(pausedByBrowser) : lastPaused ? [lastPaused] : [];
        for (const media of targets) {
          const started = apply(nativePlay, media, []);
          if (started && typeof started.catch === 'function') {
            started.catch(() => {});
          }
        }
      }
      pausedByBrowser = new Set();
    } else if (handler) {
      handler({ action });
    }
    schedule();
  };
})
)JS";

// Notices password fields and sign-ins in the page's main world. The two
// report functions are closure arguments, so the page cannot reach them. It
// reads a field's value only when its form is being sent, and fills only what the
// browser hands it after the user's click. It returns the fill function.
constexpr char kPasswordObserverScript[] = R"JS(
(function (reportForm, reportSubmit, reportAddressForm, reportAddressSubmit, reportCardForm) {
  'use strict';
  const addressKeys = ['name', 'given-name', 'family-name', 'organization', 'email', 'tel', 'street-address',
    'address-line1', 'address-line2', 'address-level1', 'address-level2', 'postal-code', 'country', 'country-name'];
  const addressPlaces = new Set(['street-address', 'address-line1', 'address-level2', 'postal-code']);
  const cardKeys = ['cc-name', 'cc-given-name', 'cc-family-name', 'cc-number', 'cc-exp', 'cc-exp-month', 'cc-exp-year'];
  function fieldsNamed(root, keys) {
    const found = {};
    for (const field of root.querySelectorAll('input,select,textarea')) {
      if (field.type === 'password' || field.type === 'hidden') continue;
      const tokens = String(field.autocomplete || '').toLowerCase().split(/\s+/);
      const key = keys.find((candidate) => tokens.includes(candidate));
      if (key && !found[key]) found[key] = field;
    }
    return found;
  }
  function addressFields(root) {
    const found = fieldsNamed(root, addressKeys);
    return Object.keys(found).some((key) => addressPlaces.has(key)) ? found : null;
  }
  function cardFields(root) {
    const found = fieldsNamed(root, cardKeys);
    return found['cc-number'] && isSecureContext ? found : null;
  }
  function isVisible(field) {
    const box = field.getBoundingClientRect();
    const style = getComputedStyle(field);
    return box.width > 1 && box.height > 1 && box.right > 0 && box.left < document.documentElement.scrollWidth &&
      box.bottom + scrollY > 0 && style.visibility === 'visible' && Number(style.opacity) > 0.05;
  }
  let addressAnnounced = false;
  let cardAnnounced = false;
  const lastSent = new Set();
  function sendFields(fields, minimum) {
    if (!fields) return;
    const values = {};
    for (const key of Object.keys(fields)) {
      const value = String(fields[key].value || '').trim();
      if (value && isVisible(fields[key])) values[key] = value;
    }
    if (Object.keys(values).length < minimum) return;
    const text = JSON.stringify(values);
    if (lastSent.has(text)) return;
    lastSent.add(text);
    reportAddressSubmit(text);
  }
  function sendAddress(root) {
    sendFields(addressFields(root), 3);
    sendFields(cardFields(root), 1);
  }
  const Input = HTMLInputElement;
  const setValue = Object.getOwnPropertyDescriptor(Input.prototype, 'value').set;
  const textTypes = new Set(['text', 'email', 'tel', '']);
  const listen = window.addEventListener.bind(window);
  let announced = false;
  let last = '';
  const passwords = (root) => Array.from(root.querySelectorAll('input[type="password"]'));
  function usernameField(password) {
    const root = password.form || document;
    const inputs = Array.from(root.querySelectorAll('input'));
    const named = inputs.find((i) => /username|email/.test(i.autocomplete || '') && textTypes.has(i.type));
    if (named) return named;
    const index = inputs.indexOf(password);
    for (let i = index - 1; i >= 0; i--) {
      if (textTypes.has(inputs[i].type)) return inputs[i];
    }
    return null;
  }
  function send(root) {
    const password = passwords(root).find((field) => field.value);
    if (!password) return;
    const user = usernameField(password);
    const username = user ? String(user.value) : '';
    const key = username + '\n' + password.value;
    if (key === last) return;
    last = key;
    reportSubmit(username, String(password.value));
  }
  function announce() {
    if (!announced && document.querySelector('input[type="password"]')) {
      announced = true;
      reportForm();
    }
    if (!addressAnnounced && addressFields(document)) {
      addressAnnounced = true;
      reportAddressForm();
    }
    if (!cardAnnounced && cardFields(document)) {
      cardAnnounced = true;
      reportCardForm();
    }
    return announced && addressAnnounced && cardAnnounced;
  }
  function watch() {
    if (announce() || !document.documentElement) return;
    const observer = new MutationObserver(() => {
      if (announce()) observer.disconnect();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type'] });
  }
  listen('submit', (event) => {
    send(event.target);
    sendAddress(event.target);
  }, true);
  listen('click', (event) => {
    const target = event.target;
    const button = target && target.closest && target.closest('button,input[type="submit"],[role="button"]');
    if (button && (!button.type || button.type === 'submit' || button.getAttribute('role') === 'button')) {
      send(button.form || document);
    }
  }, true);
  listen('keydown', (event) => {
    const target = event.target;
    if (event.key === 'Enter' && target instanceof Input && target.type === 'password') {
      send(target.form || document);
    }
  }, true);
  if (document.readyState === 'loading') {
    listen('DOMContentLoaded', watch, { once: true });
  } else {
    watch();
  }
  function put(field, value) {
    setValue.call(field, value);
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
  }
  function fillAddress(values) {
    const fields = 'cc-number' in values ? cardFields(document) : addressFields(document);
    if (!fields) return;
    for (const key of Object.keys(fields)) {
      const value = values[key];
      if (typeof value !== 'string' || fields[key].value || !isVisible(fields[key])) continue;
      if (fields[key] instanceof Input) {
        put(fields[key], value);
      } else {
        fields[key].value = value;
        fields[key].dispatchEvent(new Event('input', { bubbles: true }));
        fields[key].dispatchEvent(new Event('change', { bubbles: true }));
      }
    }
  }
  return function fill(username, password) {
    if (password === undefined) {
      fillAddress(JSON.parse(username));
      return;
    }
    const field = passwords(document)[0];
    if (!field) return;
    const user = usernameField(field);
    if (user && username) put(user, username);
    put(field, password);
  };
})
)JS";

// Notices when Chromium refuses a page the protected video it asked for: a
// Widevine, PlayReady or FairPlay request that fails while the page has a video,
// or gets one within seconds. Pages that only probe for a key system have none.
// It reports once per document; the browser may offer the page in WebKit.
constexpr char kProtectedMediaObserverScript[] = R"JS(
(function (report) {
  'use strict';
  const proto = Navigator.prototype;
  const native = proto.requestMediaKeySystemAccess;
  if (typeof native !== 'function') return;
  const apply = Reflect.apply;
  const protectedSystem = /^(com\.widevine\.alpha|com\.microsoft\.playready|com\.apple\.fps)/;
  let reported = false;
  const hasVideo = () => !!document.querySelector('video');
  function refused(system) {
    if (reported) return;
    if (hasVideo()) {
      reported = true;
      report(system);
      return;
    }
    setTimeout(() => {
      if (!reported && hasVideo()) {
        reported = true;
        report(system);
      }
    }, 3000);
  }
  proto.requestMediaKeySystemAccess = new Proxy(native, {
    apply(target, navigator, args) {
      const result = apply(target, navigator, args);
      const system = String(args[0] || '');
      if (protectedSystem.test(system) && result && typeof result.then === 'function') {
        result.then(null, () => refused(system));
      }
      return result;
    },
  });
})
)JS";

/// Reports a refused key system to the browser.
class ProtectedMediaReporter final : public CefV8Handler {
 public:
  bool Execute(const CefString&,
               CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&,
               CefString&) override {
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame || arguments.size() != 1 || !arguments[0]->IsString()) {
      return true;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kProtectedMediaRefusedMessage);
    message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(ProtectedMediaReporter);
};

/// Origins whose FairPlay audio the bridge plays in Chromium.
bool BridgesFairPlay(const std::string& url) {
  for (const char* origin : {"https://open.spotify.com/"}) {
    if (url.rfind(origin, 0) == 0) {
      return true;
    }
  }
  return false;
}

/// The protected video bridge's `send`: JSON, and for a fragment its bytes.
class ProtectedVideoSender final : public CefV8Handler {
 public:
  bool Execute(const CefString&,
               CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&,
               CefString&) override {
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame || !frame->IsMain() || arguments.empty() || !arguments[0]->IsString()) {
      return true;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kProtectedVideoMessage);
    CefRefPtr<CefListValue> values = message->GetArgumentList();
    values->SetString(0, arguments[0]->GetStringValue());
    if (arguments.size() > 1 && arguments[1]->IsArrayBuffer()) {
      const size_t length = arguments[1]->GetArrayBufferByteLength();
      void* data = arguments[1]->GetArrayBufferData();
      if (data && length > 0) {
        values->SetBinary(1, CefBinaryValue::Create(data, length));
      }
    }
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(ProtectedVideoSender);
};

/// The FairPlay bridge's `send`: its JSON goes to the browser.
class FairPlaySender final : public CefV8Handler {
 public:
  bool Execute(const CefString&,
               CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&,
               CefString&) override {
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame || !frame->IsMain() || arguments.size() != 1 || !arguments[0]->IsString()) {
      return true;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kFairPlayMessage);
    message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(FairPlaySender);
};

/// Pages whose media the sidebar follows; extension, DevTools and internal
/// pages are left alone.
bool ObservesMedia(const std::string& url) {
  for (const char* prefix : {"http://", "https://", "file://", "about:", "data:", "blob:"}) {
    if (url.rfind(prefix, 0) == 0) {
      return true;
    }
  }
  return false;
}

/// The observer's report function: sends the frame's state to the browser.
class MediaStateReporter final : public CefV8Handler {
 public:
  explicit MediaStateReporter(std::map<std::string, bool>* active) : active_(active) {}

  bool Execute(const CefString&,
               CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&,
               CefString&) override {
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame || arguments.size() != kMediaStateArgumentCount) {
      return true;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kMediaStateMessage);
    CefRefPtr<CefListValue> values = message->GetArgumentList();
    for (int index = 0; index < kMediaStateArgumentCount - 1; ++index) {
      values->SetBool(index, arguments[index]->IsBool() && arguments[index]->GetBoolValue());
    }
    const CefRefPtr<CefV8Value>& title = arguments[kMediaStateArgumentCount - 1];
    values->SetString(kMediaStateArgumentCount - 1, title->IsString() ? title->GetStringValue() : CefString());
    (*active_)[frame->GetIdentifier().ToString()] = values->GetBool(1) || values->GetBool(2);
    frame->SendProcessMessage(PID_BROWSER, message);
    return true;
  }

 private:
  std::map<std::string, bool>* active_;

  IMPLEMENT_REFCOUNTING(MediaStateReporter);
};

/// The password observer's report functions.
class PasswordReporter final : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value>,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>&,
               CefString&) override {
    CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
    if (!frame) {
      return true;
    }
    if (name == "reportForm") {
      frame->SendProcessMessage(PID_BROWSER, CefProcessMessage::Create(kPasswordFormMessage));
    } else if (name == "reportCardForm") {
      frame->SendProcessMessage(PID_BROWSER, CefProcessMessage::Create(kCardFormMessage));
    } else if (name == "reportAddressForm") {
      frame->SendProcessMessage(PID_BROWSER, CefProcessMessage::Create(kAddressFormMessage));
    } else if (name == "reportAddressSubmit") {
      if (arguments.size() == 1 && arguments[0]->IsString()) {
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kAddressSubmittedMessage);
        message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
        frame->SendProcessMessage(PID_BROWSER, message);
      }
    } else if (arguments.size() == 2 && arguments[0]->IsString() && arguments[1]->IsString()) {
      CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPasswordSubmittedMessage);
      message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
      message->GetArgumentList()->SetString(1, arguments[1]->GetStringValue());
      frame->SendProcessMessage(PID_BROWSER, message);
    }
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(PasswordReporter);
};

class RendererProcessApp : public CefApp, public CefRenderProcessHandler {
 public:
  void OnRegisterCustomSchemes(
      CefRawPtr<CefSchemeRegistrar> registrar) override {
    RegisterOpenArcCustomSchemes(registrar);
  }

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnContextCreated(CefRefPtr<CefBrowser>,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (frame && frame->IsMain() && context->IsSame(frame->GetV8Context())) {
      CefRefPtr<CefProcessMessage> process = CefProcessMessage::Create(kRendererProcessMessage);
      process->GetArgumentList()->SetInt(0, getpid());
      frame->SendProcessMessage(PID_BROWSER, process);
    }
    // CEF reports every world; extensions' content scripts get their own,
    // which must not replace the page's observer.
    if (!frame || !ObservesMedia(frame->GetURL().ToString()) || !context->IsSame(frame->GetV8Context())) {
      return;
    }
    InstallPasswordObserver(frame, context);
    // Before the media observer, which then sees the bridge's element state.
    InstallFairPlayBridge(frame, context);
    InstallProtectedVideoBridge(frame, context);
    InstallProtectedMediaObserver(frame, context);
    CefRefPtr<CefV8Value> factory;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(kMediaObserverScript, CefString(), 0, factory, exception) || !factory ||
        !factory->IsFunction()) {
      return;
    }
    CefV8ValueList arguments = {
        CefV8Value::CreateFunction("report", new MediaStateReporter(&active_frames_))};
    CefRefPtr<CefV8Value> control = factory->ExecuteFunctionWithContext(context, nullptr, arguments);
    if (control && control->IsFunction()) {
      controls_[frame->GetIdentifier().ToString()] = {context, control};
    }
  }

  void OnContextReleased(CefRefPtr<CefBrowser>,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    if (!frame) {
      return;
    }
    const std::string id = frame->GetIdentifier().ToString();
    auto control = controls_.find(id);
    if (control != controls_.end() && control->second.context->IsSame(context)) {
      controls_.erase(control);
    }
    auto fill = password_fills_.find(id);
    if (fill != password_fills_.end() && fill->second.context->IsSame(context)) {
      password_fills_.erase(fill);
    }
    auto video = protected_video_receivers_.find(id);
    if (video != protected_video_receivers_.end() && video->second.context->IsSame(context)) {
      protected_video_receivers_.erase(video);
      // The page left: its native players stop.
      CefRefPtr<CefProcessMessage> reset = CefProcessMessage::Create(kProtectedVideoMessage);
      reset->GetArgumentList()->SetString(0, "{\"op\":\"reset\"}");
      frame->SendProcessMessage(PID_BROWSER, reset);
    }
    auto fairPlay = fair_play_receivers_.find(id);
    if (fairPlay != fair_play_receivers_.end() && fairPlay->second.context->IsSame(context)) {
      fair_play_receivers_.erase(fairPlay);
      // The page left: its native player stops.
      CefRefPtr<CefProcessMessage> stop = CefProcessMessage::Create(kFairPlayMessage);
      stop->GetArgumentList()->SetString(0, "{\"op\":\"stop\"}");
      frame->SendProcessMessage(PID_BROWSER, stop);
    }
    // A page that leaves while playing stops playing.
    auto active = active_frames_.find(id);
    if (active != active_frames_.end()) {
      if (active->second) {
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kMediaStateMessage);
        CefRefPtr<CefListValue> values = message->GetArgumentList();
        for (int index = 0; index < kMediaStateArgumentCount - 1; ++index) {
          values->SetBool(index, false);
        }
        values->SetString(kMediaStateArgumentCount - 1, CefString());
        frame->SendProcessMessage(PID_BROWSER, message);
      }
      active_frames_.erase(active);
    }
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId,
                                CefRefPtr<CefProcessMessage> message) override {
    if (frame && message->GetName() == kPasswordFillMessage) {
      auto fill = password_fills_.find(frame->GetIdentifier().ToString());
      if (fill != password_fills_.end()) {
        CefRefPtr<CefListValue> values = message->GetArgumentList();
        CefV8ValueList arguments = {CefV8Value::CreateString(values->GetString(0)),
                                    CefV8Value::CreateString(values->GetString(1))};
        fill->second.function->ExecuteFunctionWithContext(fill->second.context, nullptr, arguments);
      }
      return true;
    }
    if (frame && message->GetName() == kProtectedVideoEventMessage) {
      auto receiver = protected_video_receivers_.find(frame->GetIdentifier().ToString());
      if (receiver != protected_video_receivers_.end()) {
        CefV8ValueList arguments = {CefV8Value::CreateString(message->GetArgumentList()->GetString(0))};
        receiver->second.function->ExecuteFunctionWithContext(receiver->second.context, nullptr, arguments);
      }
      return true;
    }
    if (frame && message->GetName() == kFairPlayEventMessage) {
      auto receiver = fair_play_receivers_.find(frame->GetIdentifier().ToString());
      if (receiver != fair_play_receivers_.end()) {
        CefV8ValueList arguments = {CefV8Value::CreateString(message->GetArgumentList()->GetString(0))};
        receiver->second.function->ExecuteFunctionWithContext(receiver->second.context, nullptr, arguments);
      }
      return true;
    }
    if (frame && message->GetName() == kAddressFillMessage) {
      auto fill = password_fills_.find(frame->GetIdentifier().ToString());
      if (fill != password_fills_.end()) {
        CefV8ValueList arguments = {CefV8Value::CreateString(message->GetArgumentList()->GetString(0))};
        fill->second.function->ExecuteFunctionWithContext(fill->second.context, nullptr, arguments);
      }
      return true;
    }
    if (!frame || message->GetName() != kMediaControlMessage) {
      return false;
    }
    auto control = controls_.find(frame->GetIdentifier().ToString());
    if (control == controls_.end()) {
      return true;
    }
    CefV8ValueList arguments = {CefV8Value::CreateString(message->GetArgumentList()->GetString(0))};
    control->second.function->ExecuteFunctionWithContext(control->second.context, nullptr, arguments);
    return true;
  }

 private:
  struct MediaControl {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> function;
  };

  void InstallPasswordObserver(CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) {
    // The browser decides by the frame's address when a message arrives: this
    // early a new document may not report its address yet.
    CefRefPtr<CefV8Value> factory;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(kPasswordObserverScript, CefString(), 0, factory, exception) || !factory ||
        !factory->IsFunction()) {
      return;
    }
    CefRefPtr<CefV8Handler> reporter = new PasswordReporter();
    CefV8ValueList arguments = {CefV8Value::CreateFunction("reportForm", reporter),
                                CefV8Value::CreateFunction("reportSubmit", reporter),
                                CefV8Value::CreateFunction("reportAddressForm", reporter),
                                CefV8Value::CreateFunction("reportAddressSubmit", reporter),
                                CefV8Value::CreateFunction("reportCardForm", reporter)};
    CefRefPtr<CefV8Value> fill = factory->ExecuteFunctionWithContext(context, nullptr, arguments);
    if (fill && fill->IsFunction()) {
      password_fills_[frame->GetIdentifier().ToString()] = {context, fill};
    }
  }

  void InstallProtectedMediaObserver(CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) {
    const std::string url = frame->GetURL().ToString();
    if (url.rfind("https://", 0) != 0 && url.rfind("http://", 0) != 0) {
      return;
    }
    CefRefPtr<CefV8Value> factory;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(kProtectedMediaObserverScript, CefString(), 0, factory, exception) || !factory ||
        !factory->IsFunction()) {
      return;
    }
    CefV8ValueList arguments = {CefV8Value::CreateFunction("report", new ProtectedMediaReporter())};
    factory->ExecuteFunctionWithContext(context, nullptr, arguments);
  }

  void InstallFairPlayBridge(CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) {
    if (!frame->IsMain() || !BridgesFairPlay(frame->GetURL().ToString())) {
      return;
    }
    CefRefPtr<CefV8Value> factory;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(kFairPlayBridgeScript, CefString(), 0, factory, exception) || !factory ||
        !factory->IsFunction()) {
      return;
    }
    CefV8ValueList arguments = {CefV8Value::CreateFunction("send", new FairPlaySender())};
    CefRefPtr<CefV8Value> receive = factory->ExecuteFunctionWithContext(context, nullptr, arguments);
    if (receive && receive->IsFunction()) {
      fair_play_receivers_[frame->GetIdentifier().ToString()] = {context, receive};
    }
  }

  void InstallProtectedVideoBridge(CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) {
    if (!frame->IsMain() || !BridgesProtectedVideo(frame->GetURL().ToString()) || !ProtectedMediaBridgeOn()) {
      return;
    }
    CefRefPtr<CefV8Value> factory;
    CefRefPtr<CefV8Exception> exception;
    if (!context->Eval(kProtectedVideoBridgeScript, CefString(), 0, factory, exception) || !factory ||
        !factory->IsFunction()) {
      return;
    }
    CefV8ValueList arguments = {CefV8Value::CreateFunction("send", new ProtectedVideoSender()),
                                CefV8Value::CreateString(SafariUserAgent())};
    CefRefPtr<CefV8Value> receive = factory->ExecuteFunctionWithContext(context, nullptr, arguments);
    if (receive && receive->IsFunction()) {
      protected_video_receivers_[frame->GetIdentifier().ToString()] = {context, receive};
    }
  }

  std::map<std::string, MediaControl> protected_video_receivers_;
  std::map<std::string, MediaControl> fair_play_receivers_;
  std::map<std::string, MediaControl> password_fills_;
  std::map<std::string, MediaControl> controls_;
  // Frames whose last report said they were playing, by frame identifier.
  std::map<std::string, bool> active_frames_;

  IMPLEMENT_REFCOUNTING(RendererProcessApp);
};

}  // namespace

CefRefPtr<CefApp> CreateRendererProcessApp() {
  return new RendererProcessApp();
}

}  // namespace shared
