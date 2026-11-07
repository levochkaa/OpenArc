#ifndef OPENARC_SHARED_CLIENT_MANAGER_H_
#define OPENARC_SHARED_CLIENT_MANAGER_H_

#include <list>

#include "include/base/cef_thread_checker.h"
#include "include/cef_browser.h"

namespace shared {

class ClientManager {
 public:
  ClientManager();
  ~ClientManager();

  static ClientManager* GetInstance();

  void OnAfterCreated(CefRefPtr<CefBrowser> browser);
  void DoClose(CefRefPtr<CefBrowser> browser);
  void OnBeforeClose(CefRefPtr<CefBrowser> browser);
  void CloseAllBrowsers(bool force_close);
  bool IsClosing() const;
  bool HasBrowsers() const;

 private:
  base::ThreadChecker thread_checker_;
  bool is_closing_;
  // Set once quitting closes every browser; only then does the last close end the
  // message loop. A window may close its only page and stay open.
  bool quits_when_empty_ = false;
  std::list<CefRefPtr<CefBrowser>> browser_list_;
};

}  // namespace shared

#endif  // OPENARC_SHARED_CLIENT_MANAGER_H_
