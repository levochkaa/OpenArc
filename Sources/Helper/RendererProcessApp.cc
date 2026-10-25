#include <map>
#include <string>

#include "Shared/AppFactory.h"
#include "Shared/BrowserMediaMessages.h"
#include "Shared/BrowserSchemes.h"
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
      actions.has('nexttrack'), metadata && metadata.title ? String(metadata.title) : ''];
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
    // CEF reports every world; extensions' content scripts get their own,
    // which must not replace the page's observer.
    if (!frame || !ObservesMedia(frame->GetURL().ToString()) || !context->IsSame(frame->GetV8Context())) {
      return;
    }
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
