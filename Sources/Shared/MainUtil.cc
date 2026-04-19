#include "Shared/MainUtil.h"

namespace shared {

namespace {

constexpr char kProcessType[] = "type";
constexpr char kRendererProcess[] = "renderer";

}  // namespace

CefRefPtr<CefCommandLine> CreateCommandLine(const CefMainArgs& main_args) {
  CefRefPtr<CefCommandLine> command_line = CefCommandLine::CreateCommandLine();
  command_line->InitFromArgv(main_args.argc, main_args.argv);
  return command_line;
}

ProcessType GetProcessType(const CefRefPtr<CefCommandLine>& command_line) {
  if (!command_line->HasSwitch(kProcessType)) {
    return PROCESS_TYPE_BROWSER;
  }

  const std::string& process_type = command_line->GetSwitchValue(kProcessType);
  if (process_type == kRendererProcess) {
    return PROCESS_TYPE_RENDERER;
  }

  return PROCESS_TYPE_OTHER;
}

}  // namespace shared

