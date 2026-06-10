#import "Browser/SwiftBridge.h"

#include <dlfcn.h>

#include "base/time/time.h"
#include "include/cef_task.h"

namespace {

using StartThrottlingAllFrameSinks = void (*)(base::TimeDelta);
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
      start_throttling(base::Hertz(30));
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
  const bool is_enabled = enabled == YES;
  if (CefCurrentlyOn(TID_UI)) {
    ApplyBatterySaverModeOnUI(is_enabled);
    return;
  }

  CefPostTask(TID_UI, new BatterySaverModeTask(is_enabled));
}
