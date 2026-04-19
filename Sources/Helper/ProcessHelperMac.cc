#include "Helper/ProcessHelperMac.h"

#include "Shared/AppFactory.h"
#include "Shared/MainUtil.h"

#include "include/wrapper/cef_library_loader.h"

namespace shared {

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  CefRefPtr<CefCommandLine> command_line = CreateCommandLine(main_args);

  CefRefPtr<CefApp> app;
  switch (GetProcessType(command_line)) {
    case PROCESS_TYPE_RENDERER:
      app = CreateRendererProcessApp();
      break;
    case PROCESS_TYPE_OTHER:
      app = CreateOtherProcessApp();
      break;
    case PROCESS_TYPE_BROWSER:
      break;
  }

  return CefExecuteProcess(main_args, app, nullptr);
}

}  // namespace shared

