#import "Browser/SwiftBridge.h"

#include <dlfcn.h>

#include <cstdint>

#include "include/cef_task.h"

namespace {

// The engine's base::TimeDelta: one int64_t of microseconds, trivially copyable,
// so it is passed exactly like this struct.
struct EngineTimeDelta {
  int64_t microseconds;
};

using StartThrottlingAllFrameSinks = void (*)(EngineTimeDelta);
using StopThrottlingAllFrameSinks = void (*)();

constexpr char kStartThrottlingAllFrameSinksSymbol[] =
    "__ZN7content28StartThrottlingAllFrameSinksEN4base9TimeDeltaE";
constexpr char kStopThrottlingAllFrameSinksSymbol[] =
    "__ZN7content27StopThrottlingAllFrameSinksEv";

bool gBatterySaverModeEnabled = false;

void ApplyBatterySaverModeOnUI(bool enabled);

template <typename Function>
Function ResolveContentSymbol(const char* symbol_name) {
  void* symbol = dlsym(RTLD_DEFAULT, symbol_name);
  if (symbol) {
    return reinterpret_cast<Function>(symbol);
  }

  void* content_handle = dlopen("libcontent.dylib", RTLD_NOW | RTLD_NOLOAD);
  if (!content_handle) {
    return nullptr;
  }

  return reinterpret_cast<Function>(dlsym(content_handle, symbol_name));
}

class BatterySaverModeTask : public CefTask {
 public:
  explicit BatterySaverModeTask(bool enabled) : enabled_(enabled) {}

  void Execute() override {
    ApplyBatterySaverModeOnUI(enabled_);
  }

 private:
  const bool enabled_;

  IMPLEMENT_REFCOUNTING(BatterySaverModeTask);
};

void ApplyBatterySaverModeOnUI(bool enabled) {
  if (gBatterySaverModeEnabled == enabled) {
    return;
  }

  gBatterySaverModeEnabled = enabled;
  if (enabled) {
    auto start_throttling =
        ResolveContentSymbol<StartThrottlingAllFrameSinks>(
            kStartThrottlingAllFrameSinksSymbol);
    if (start_throttling) {
      start_throttling(EngineTimeDelta{1'000'000 / 30});
    }
  } else {
    auto stop_throttling = ResolveContentSymbol<StopThrottlingAllFrameSinks>(
        kStopThrottlingAllFrameSinksSymbol);
    if (stop_throttling) {
      stop_throttling();
    }
  }
}

}  // namespace

void BrowserSetBatterySaverModeEnabled(BOOL enabled) {
  // Chrome's framework throttles its own pages; CEF's task runner is not there.
  if (BrowserUsesChromeEngine()) {
    return;
  }
  const bool is_enabled = enabled == YES;
  if (CefCurrentlyOn(TID_UI)) {
    ApplyBatterySaverModeOnUI(is_enabled);
    return;
  }

  CefPostTask(TID_UI, new BatterySaverModeTask(is_enabled));
}
