// Chrome's permission prompts for OpenArc's pages, shown by OpenArc in its own window. Modeled on CEF's
// permission prompt (libcef/browser/permission_prompt.cc), which hands Chrome's requests to OpenArc's prompt on
// CEF: Allow, Block or no answer, and Chrome remembers the site's answer.

#import "openarc/permission_prompt.h"

#include <algorithm>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/request_type.h"
#import "openarc/BrowserChromeEngine.h"

namespace openarc {

namespace {

uint64_t g_next_prompt_id = 0;

// The BrowserSitePermissionKind raw value of a request; a request without a kind of its own is "other".
std::string_view KindForRequest(permissions::RequestType type) {
  using permissions::RequestType;
  switch (type) {
    case RequestType::kCameraStream:
    case RequestType::kCameraPanTiltZoom:
      return "camera";
    case RequestType::kMicStream:
      return "microphone";
    case RequestType::kGeolocation:
      return "location";
    case RequestType::kNotifications:
      return "notifications";
    case RequestType::kClipboard:
      return "clipboard";
    case RequestType::kMidiSysex:
      return "midi";
    case RequestType::kWindowManagement:
      return "windowManagement";
    case RequestType::kLocalFonts:
      return "localFonts";
    case RequestType::kIdleDetection:
      return "idleDetection";
    case RequestType::kStorageAccess:
    case RequestType::kTopLevelStorageAccess:
      return "storageAccess";
    case RequestType::kMultipleDownloads:
      return "multipleDownloads";
    default:
      return "other";
  }
}

// The kinds of the requests, in the order OpenArc's prompt lists them (as CEF's SitePermissionKindsForPrompt in
// BrowserTabController.mm).
NSArray<NSString*>* KindsForRequests(const permissions::PermissionPrompt::Delegate& delegate) {
  constexpr std::string_view kOrder[] = {
      "camera",     "microphone",    "location",      "notifications",     "clipboard", "midi", "windowManagement",
      "localFonts", "idleDetection", "storageAccess", "multipleDownloads", "other",
  };
  NSMutableArray<NSString*>* kinds = [NSMutableArray array];
  for (std::string_view kind : kOrder) {
    if (std::ranges::any_of(delegate.Requests(),
                            [kind](const auto& request) { return KindForRequest(request->request_type()) == kind; })) {
      [kinds addObject:base::SysUTF8ToNSString(kind)];
    }
  }
  return kinds;
}

class OpenArcPermissionPrompt : public permissions::PermissionPrompt {
 public:
  OpenArcPermissionPrompt(id page, id<BrowserChromePageDelegate> page_delegate, Delegate* delegate)
      : page_(page), page_delegate_(page_delegate), delegate_(delegate), id_(++g_next_prompt_id) {}

  OpenArcPermissionPrompt(const OpenArcPermissionPrompt&) = delete;
  OpenArcPermissionPrompt& operator=(const OpenArcPermissionPrompt&) = delete;

  // Chrome is done with the requests: answered, or withdrawn by a navigation, the page closing or a request
  // ahead of them, which closes OpenArc's prompt.
  ~OpenArcPermissionPrompt() override {
    id page = page_;
    id<BrowserChromePageDelegate> page_delegate = page_delegate_;
    if (!answered_ && page && [page_delegate respondsToSelector:@selector(chromePage:didWithdrawSitePermissionPrompt:)]) {
      [page_delegate chromePage:page didWithdrawSitePermissionPrompt:id_];
    }
  }

  // Asks OpenArc. False when it leaves the requests to Chrome.
  bool Show() {
    id page = page_;
    id<BrowserChromePageDelegate> page_delegate = page_delegate_;
    SEL selector = @selector(chromePage:requestSitePermissionPrompt:origin:kinds:decision:);
    NSArray<NSString*>* kinds = KindsForRequests(*delegate_);
    if (!page || ![page_delegate respondsToSelector:selector] || kinds.count == 0) {
      answered_ = true;
      return false;
    }
    base::WeakPtr<OpenArcPermissionPrompt> weak = weak_factory_.GetWeakPtr();
    // The answer reaches Chrome in a task of its own: an answer from inside Chrome's call to make the prompt would
    // find the request manager mid-change.
    void (^decision)(NSNumber*) = ^(NSNumber* allowed) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&OpenArcPermissionPrompt::Answer, weak, allowed == nil ? -1 : allowed.boolValue));
    };
    const BOOL shown = [page_delegate chromePage:page
                      requestSitePermissionPrompt:id_
                                           origin:base::SysUTF8ToNSString(delegate_->GetRequestingOrigin().spec())
                                            kinds:kinds
                                         decision:decision];
    // A prompt OpenArc never showed has nothing to withdraw.
    answered_ = !shown;
    return shown;
  }

  // permissions::PermissionPrompt:
  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override { return TabSwitchingBehavior::kKeepPromptAlive; }
  permissions::PermissionPromptDisposition GetPromptDisposition() const override {
    return permissions::PermissionPromptDisposition::CUSTOM_MODAL_DIALOG;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override { return std::nullopt; }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants() const override { return {}; }
  std::optional<permissions::feature_params::PermissionElementPromptPosition> GetPromptPosition() const override {
    return std::nullopt;
  }

 private:
  // 1 allows, 0 blocks, -1 closes without an answer. Chrome may destroy the prompt inside the call, so nothing
  // here touches it after.
  void Answer(int allowed) {
    if (answered_) {
      return;
    }
    answered_ = true;
    const PromptOptions options(std::monostate{});
    if (allowed == 1) {
      delegate_->Accept(options);
    } else if (allowed == 0) {
      delegate_->Deny(options);
    } else {
      delegate_->Dismiss(options);
    }
  }

  __weak id page_;
  __weak id<BrowserChromePageDelegate> page_delegate_;
  // The PermissionRequestManager, which owns this prompt.
  const raw_ptr<Delegate> delegate_;
  const uint64_t id_;
  bool answered_ = false;
  base::WeakPtrFactory<OpenArcPermissionPrompt> weak_factory_{this};
};

}  // namespace

std::unique_ptr<permissions::PermissionPrompt> CreatePermissionPrompt(id page,
                                                                      id<BrowserChromePageDelegate> page_delegate,
                                                                      permissions::PermissionPrompt::Delegate* delegate) {
  auto prompt = std::make_unique<OpenArcPermissionPrompt>(page, page_delegate, delegate);
  if (!prompt->Show()) {
    return nullptr;
  }
  return prompt;
}

}  // namespace openarc
